// @ts-nocheck
//
// ════════════════════════════════════════════════════════════════════════════
// VINCULACIÓN DE TELEVISORES
// ════════════════════════════════════════════════════════════════════════════
//
// El televisor muestra un código, el teléfono lo escribe. Aquí se decide si
// quien lo escribe es premium de verdad, y solo entonces se emite el token.
//
// POR QUÉ ESTO NO PUEDE VIVIR EN LA APP
// El APK del televisor se reparte a mano. Un APK en manos de alguien es un
// archivo que se puede abrir: cualquier secreto que lleve dentro es un secreto
// público. Por eso el televisor no valida nada — solo enseña un código y
// guarda lo que este servidor le dé.
//
// Y por eso también la comprobación de "es premium" se hace AQUÍ contra la API
// de RevenueCat. Si el teléfono mandara un `esPremium: true` y nos fiáramos,
// la suscripción entera sería una casilla que cualquiera puede marcar.
//
// SECRETOS (Supabase → Edge Functions → Secrets):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY   (los pone Supabase)
//   REVENUECAT_SECRET_KEY                     (clave v1 "secret", NO la pública)
//
// La `service_role` no sale de aquí jamás. Ninguna de las dos apps la ve.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

// Cuántos televisores puede tener vinculados una misma cuenta.
//
// Este número, y no la caducidad del código, es lo que de verdad frena que se
// preste el acceso: pasarle el código a un amigo te cuesta una de tus plazas.
const MAX_TVS = 2;

const VIGENCIA_CODIGO_MIN = 10;
const MAX_INTENTOS = 8;

// Alfabeto sin caracteres que se confundan al leerlos en una pantalla desde el
// sofá: fuera O/0, I/1, y también S/5 y B/8, que a distancia se parecen.
const ALFABETO = "ACDEFGHJKLMNPQRTUVWXYZ2346789";

function nuevoCodigo(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  let s = "";
  for (let i = 0; i < 8; i++) s += ALFABETO[bytes[i] % ALFABETO.length];
  return s.slice(0, 4) + "-" + s.slice(4);
}

function nuevoToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// ── ¿Es premium este usuario? ──────────────────────────────────────────────
//
// Devuelve { ok, hasta } — `hasta` es cuándo caduca, para que el televisor
// sepa cuándo volver a preguntar.
async function verificarPremium(
  supabase: any,
  userRef: string,
  userKind: string,
): Promise<{ ok: boolean; hasta: string | null; motivo?: string }> {
  // RevenueCat es la fuente de verdad de las suscripciones.
  // `userKind` se conserva en la firma y en la tabla por si algun dia hay
  // otra via, pero hoy solo existe esta.
  const clave =
    Deno.env.get("REVENUECAT_SECRET_KEY") ??
    "goog_choPIwxbmFDjcTSaglVwWRsEGYR";
  if (!clave) {
    // Sin clave configurada NO se abre la puerta. Un fallo de despliegue no
    // puede convertirse en "premium para todo el mundo".
    return { ok: false, hasta: null, motivo: "servidor_sin_configurar" };
  }

  const rs = await fetch(
    `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userRef)}`,
    { headers: { Authorization: `Bearer ${clave}` } },
  );

  if (!rs.ok) return { ok: false, hasta: null, motivo: "revenuecat_error" };

  const cuerpo = await rs.json();
  const activos = cuerpo?.subscriber?.entitlements ?? {};
  const ahora = Date.now();
  let mejor: string | null = null;

  for (const nombre of Object.keys(activos)) {
    const e = activos[nombre];
    // `expires_date` a null = permanente (una compra de por vida).
    if (!e?.expires_date) return { ok: true, hasta: null };
    const t = new Date(e.expires_date).getTime();
    if (t > ahora && (mejor === null || t > new Date(mejor).getTime())) {
      mejor = e.expires_date;
    }
  }

  return mejor
    ? { ok: true, hasta: mejor }
    : { ok: false, hasta: null, motivo: "sin_suscripcion_activa" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    );

    const cuerpo = await req.json();
    const accion = cuerpo?.accion;

    // ═══ TELEVISOR: pedir un código ═══════════════════════════════════════
    if (accion === "crear") {
      const deviceId = String(cuerpo.deviceId ?? "").trim();
      if (!deviceId) return json({ error: "falta deviceId" }, 400);

      // Si ese televisor ya tenía un código vivo, se le devuelve el mismo. Sin
      // esto, cada repintado de la pantalla generaría uno nuevo y el usuario
      // estaría tecleando un código que acaba de dejar de existir.
      const { data: vivo } = await supabase
        .from("tv_pairings")
        .select("code, expires_at")
        .eq("device_id", deviceId)
        .is("claimed_at", null)
        .gt("expires_at", new Date().toISOString())
        .maybeSingle();

      if (vivo) return json({ code: vivo.code, expiraEn: vivo.expires_at });

      const code = nuevoCodigo();
      const expira = new Date(
        Date.now() + VIGENCIA_CODIGO_MIN * 60_000,
      ).toISOString();

      const { error } = await supabase.from("tv_pairings").insert({
        code,
        device_id: deviceId,
        device_name: String(cuerpo.deviceName ?? "").slice(0, 80) || null,
        expires_at: expira,
      });
      if (error) throw error;

      return json({ code, expiraEn: expira });
    }

    // ═══ TELEVISOR: ¿ya lo canjearon? ═════════════════════════════════════
    if (accion === "estado") {
      const code = String(cuerpo.code ?? "").trim().toUpperCase();
      const deviceId = String(cuerpo.deviceId ?? "").trim();
      if (!code || !deviceId) return json({ error: "faltan datos" }, 400);

      const { data } = await supabase
        .from("tv_pairings")
        .select("device_id, claimed_at, device_token, expires_at")
        .eq("code", code)
        .maybeSingle();

      if (!data) return json({ estado: "desconocido" });
      // El token solo se entrega al aparato que pidió ESE código.
      if (data.device_id !== deviceId) return json({ estado: "desconocido" });

      if (data.claimed_at && data.device_token) {
        // Entregado: la fila ya no hace falta y el token deja de estar en una
        // tabla de códigos temporales.
        await supabase.from("tv_pairings").delete().eq("code", code);
        return json({ estado: "vinculado", token: data.device_token });
      }

      if (new Date(data.expires_at) < new Date()) {
        return json({ estado: "caducado" });
      }
      return json({ estado: "pendiente" });
    }

    // ═══ TELÉFONO: canjear el código ══════════════════════════════════════
    if (accion === "canjear") {
      const code = String(cuerpo.code ?? "").trim().toUpperCase();
      const userRef = String(cuerpo.userRef ?? "").trim();
      const userKind = String(cuerpo.userKind ?? "revenuecat");
      // Configuracion de fuentes del telefono.
      //
      // El televisor es una instalacion aparte y arranca con las preferencias
      // vacias: sin esto su catalogo sale vacio siempre, porque las
      // credenciales del proveedor viven en el telefono.
      //
      // Viaja aqui y no por la red local para que el TV siga funcionando
      // aunque el telefono este apagado o fuera de casa.
      const sources = typeof cuerpo.sources === "string"
        ? cuerpo.sources.slice(0, 200_000)
        : null;

      if (!code || !userRef) return json({ error: "faltan datos" }, 400);

      const { data: par } = await supabase
        .from("tv_pairings")
        .select("*")
        .eq("code", code)
        .maybeSingle();

      if (!par) {
        return json({ ok: false, motivo: "codigo_invalido" });
      }
      if (par.attempts >= MAX_INTENTOS) {
        return json({ ok: false, motivo: "demasiados_intentos" });
      }
      if (new Date(par.expires_at) < new Date()) {
        return json({ ok: false, motivo: "codigo_caducado" });
      }
      if (par.claimed_at) {
        return json({ ok: false, motivo: "codigo_ya_usado" });
      }

      // La comprobación de premium va DESPUÉS de las validaciones baratas,
      // para no gastar una llamada a RevenueCat por cada código mal escrito.
      const premium = await verificarPremium(supabase, userRef, userKind);
      if (!premium.ok) {
        await supabase
          .from("tv_pairings")
          .update({ attempts: par.attempts + 1 })
          .eq("code", code);
        return json({ ok: false, motivo: premium.motivo ?? "no_premium" });
      }

      // ── El tope de televisores ──────────────────────────────────────────
      // Revincular el mismo aparato no gasta plaza: se comprueba si ya existe
      // antes de contar.
      const { data: yaEste } = await supabase
        .from("tv_devices")
        .select("id")
        .eq("user_ref", userRef)
        .eq("device_id", par.device_id)
        .maybeSingle();

      if (!yaEste) {
        const { count } = await supabase
          .from("tv_devices")
          .select("id", { count: "exact", head: true })
          .eq("user_ref", userRef)
          .is("revoked_at", null);

        if ((count ?? 0) >= MAX_TVS) {
          return json({ ok: false, motivo: "limite_dispositivos", max: MAX_TVS });
        }
      }

      const token = nuevoToken();

      const { error: errUp } = await supabase.from("tv_devices").upsert(
        {
          user_ref: userRef,
          user_kind: userKind,
          device_id: par.device_id,
          device_name: par.device_name,
          device_token: token,
          revoked_at: null,
          last_seen_at: new Date().toISOString(),
          // Solo se pisa si el telefono manda algo: revincular sin enviarlas
          // no debe dejar al televisor sin catalogo.
          ...(sources ? { sources } : {}),
        },
        { onConflict: "user_ref,device_id" },
      );
      if (errUp) throw errUp;

      await supabase
        .from("tv_pairings")
        .update({
          claimed_at: new Date().toISOString(),
          claimed_by: userRef,
          device_token: token,
        })
        .eq("code", code);

      return json({ ok: true, nombre: par.device_name });
    }

    // ═══ TELEVISOR: ¿sigo teniendo derecho? ═══════════════════════════════
    //
    // Se llama al arrancar. Sin esto un token valdría para siempre y dar de
    // baja la suscripción no cerraría nada.
    if (accion === "validar") {
      const token = String(cuerpo.token ?? "").trim();
      if (!token) return json({ ok: false, motivo: "sin_token" });

      const { data: dev } = await supabase
        .from("tv_devices")
        .select("*")
        .eq("device_token", token)
        .maybeSingle();

      if (!dev) return json({ ok: false, motivo: "token_desconocido" });
      if (dev.revoked_at) return json({ ok: false, motivo: "revocado" });

      const premium = await verificarPremium(
        supabase,
        dev.user_ref,
        dev.user_kind,
      );

      await supabase
        .from("tv_devices")
        .update({ last_seen_at: new Date().toISOString() })
        .eq("id", dev.id);

      if (!premium.ok) {
        return json({ ok: false, motivo: premium.motivo ?? "no_premium" });
      }
      // Las fuentes viajan en la validacion, que es la que corre al arrancar
      // el televisor. Asi un cambio de proveedor en el telefono llega solo al
      // TV en el siguiente arranque, sin volver a vincular.
      return json({ ok: true, hasta: premium.hasta, sources: dev.sources ?? null });
    }

    // ═══ TELÉFONO: ver y quitar televisores ═══════════════════════════════
    if (accion === "listar") {
      const userRef = String(cuerpo.userRef ?? "").trim();
      if (!userRef) return json({ error: "falta userRef" }, 400);

      const { data } = await supabase
        .from("tv_devices")
        .select("id, device_name, created_at, last_seen_at")
        .eq("user_ref", userRef)
        .is("revoked_at", null)
        .order("created_at", { ascending: true });

      return json({ dispositivos: data ?? [], max: MAX_TVS });
    }

    if (accion === "revocar") {
      const userRef = String(cuerpo.userRef ?? "").trim();
      const id = String(cuerpo.id ?? "").trim();
      if (!userRef || !id) return json({ error: "faltan datos" }, 400);

      // El `user_ref` en el WHERE no es adorno: sin él, cualquiera podría
      // desvincular el televisor de otro sabiendo su id.
      const { error } = await supabase
        .from("tv_devices")
        .update({ revoked_at: new Date().toISOString() })
        .eq("id", id)
        .eq("user_ref", userRef);
      if (error) throw error;

      return json({ ok: true });
    }

    return json({ error: "accion desconocida" }, 400);
  } catch (e) {
    console.error("tv-pairing:", e);
    return json({ error: "error interno" }, 500);
  }
});
