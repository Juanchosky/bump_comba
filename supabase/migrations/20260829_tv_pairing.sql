-- ═══════════════════════════════════════════════════════════════════════════
-- VINCULACIÓN DE TELEVISORES A UNA CUENTA PREMIUM
-- ═══════════════════════════════════════════════════════════════════════════
--
-- El APK del televisor se reparte a mano, fuera de Play Store, así que ahí no
-- hay ni cuenta ni compra: el TV no puede saber por sí mismo si quien lo usa
-- es premium.
--
-- Se resuelve al revés de lo que uno esperaría: el código lo MUESTRA el
-- televisor y lo ESCRIBE el teléfono, que es donde vive la suscripción. Así no
-- se teclea nada con el mando, y lo que queda vinculado es la cuenta con ese
-- aparato concreto — no "alguien premium que estaba cerca un momento".
--
-- NINGUNA DE LAS DOS APPS TOCA ESTAS TABLAS.
-- Van sin políticas RLS a propósito: con RLS activo y cero políticas, la clave
-- `anon` no puede leer ni escribir nada. Todo pasa por la Edge Function
-- `tv-pairing`, que es la única que usa `service_role`. Si la app pudiera
-- escribir aquí, cualquiera con el APK descompilado se emitiría un token.

-- ── Televisores ya vinculados ──────────────────────────────────────────────
create table if not exists public.tv_devices (
  id uuid primary key default gen_random_uuid(),

  -- A quién pertenece: el `appUserID` de RevenueCat.
  --
  -- `user_kind` queda por si algún día hay otra vía de cobro, pero hoy solo
  -- existe 'revenuecat'. Hubo un camino de licencias para la versión de
  -- escritorio; se retiró al dejar de venderse.
  user_ref  text not null,
  user_kind text not null default 'revenuecat',

  device_id   text not null,
  device_name text,

  -- Lo único que el televisor guarda. No es una contraseña del usuario: es un
  -- secreto de ESTE aparato, y se puede revocar solo.
  device_token text not null unique,

  -- Configuracion de fuentes del telefono, en JSON.
  --
  -- El televisor arranca con las preferencias vacias y no tiene de donde sacar
  -- titulos: las credenciales del proveedor viven en el telefono. Se guardan
  -- aqui para que el TV funcione aunque el telefono este apagado.
  --
  -- OJO: son credenciales. Esta tabla va sin politicas RLS a proposito, asi que
  -- solo las lee la Edge Function con `service_role`; nunca la clave `anon`.
  sources text,

  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,

  -- Revocar no borra: deja rastro de que ese televisor existió, que es lo que
  -- permite explicarle al usuario por qué dejó de funcionar.
  revoked_at timestamptz,

  -- Volver a vincular el MISMO televisor no gasta una plaza nueva.
  unique (user_ref, device_id)
);

create index if not exists tv_devices_user_activos
  on public.tv_devices (user_ref)
  where revoked_at is null;

create index if not exists tv_devices_token
  on public.tv_devices (device_token)
  where revoked_at is null;

-- ── Códigos pendientes de canjear ──────────────────────────────────────────
create table if not exists public.tv_pairings (
  -- Formato XXXX-XXXX con alfabeto sin ambigüedades (ver la Edge Function).
  code text primary key,

  device_id   text not null,
  device_name text,

  created_at timestamptz not null default now(),

  -- Diez minutos: de sobra para ir a por el teléfono, y poco para que un
  -- código abandonado en pantalla siga sirviendo mañana.
  expires_at timestamptz not null,

  claimed_at timestamptz,
  claimed_by text,

  -- El token viaja aquí una sola vez: el televisor lo recoge en su siguiente
  -- consulta y la fila se puede limpiar.
  device_token text,

  -- Contra la fuerza bruta. Un código son 8 caracteres de un alfabeto de 31;
  -- con este contador, adivinarlo a base de intentos deja de ser viable.
  attempts int not null default 0
);

create index if not exists tv_pairings_caducidad
  on public.tv_pairings (expires_at);

-- RLS activo y CERO políticas = nadie entra salvo `service_role`.
alter table public.tv_devices  enable row level security;
alter table public.tv_pairings enable row level security;

-- ── Limpieza ───────────────────────────────────────────────────────────────
-- Los códigos caducados no sirven para nada y la tabla crece con cada
-- televisor que abrió la pantalla y se arrepintió.
create or replace function public.limpiar_tv_pairings()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.tv_pairings
   where expires_at < now() - interval '1 hour';
$$;
