# Vincular televisores a una cuenta premium

El APK del TV se reparte a mano, fuera de Play Store, así que allí no hay ni
cuenta ni compra. Esto lo resuelve al revés de lo que uno esperaría: **el
código lo muestra el televisor y lo escribe el teléfono**, que es donde vive la
suscripción.

Así no se teclea nada con el mando, y lo que queda vinculado es la cuenta con
ese aparato — no "alguien premium que pasaba por ahí".

---

## 1. Crear las tablas

En **Supabase → SQL Editor**, pega y ejecuta:

```
supabase/migrations/20260829_tv_pairing.sql
```

Crea `tv_devices` y `tv_pairings`, ambas con RLS activo y **cero políticas**.
Eso es a propósito: con RLS y sin políticas, la clave `anon` no puede tocarlas.
Solo entra la Edge Function.

## 2. Configurar el secreto de RevenueCat

Necesitas la clave **secreta** v1 (RevenueCat → Project settings → API keys →
`sk_...`). **No es la pública** que ya lleva la app.

En Supabase → Edge Functions → Secrets:

```bash
supabase secrets set REVENUECAT_SECRET_KEY=sk_TU_CLAVE_AQUI
```

Esta clave **no puede salir del servidor bajo ningún concepto**: ni en la app,
ni en el repo, ni en un archivo servido por nginx. Con ella se consulta el
estado de suscripción de cualquier usuario. Mismo criterio que la
`service_role` de `alias-tmdb.sh`.

Si falta, la función **deniega** todas las vinculaciones. Es deliberado: un
fallo de despliegue no puede convertirse en "premium para todo el mundo".

## 3. Desplegar la función

```bash
supabase functions deploy tv-pairing
```

`SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY` las inyecta Supabase sola.

## 4. Comprobar que responde

```bash
curl -s -X POST "https://TU-PROYECTO.supabase.co/functions/v1/tv-pairing" -H "Authorization: Bearer TU_ANON_KEY" -H "Content-Type: application/json" -d '{"accion":"crear","deviceId":"prueba-1","deviceName":"Prueba"}'
```

Debe devolver algo como `{"code":"K7F2-9QXA","expiraEn":"..."}`. Si devuelve
`error interno`, mira los logs en Supabase → Edge Functions → tv-pairing.

## 5. Limpieza (opcional pero recomendable)

Los códigos caducados se acumulan. En Supabase → Database → Cron:

```sql
select cron.schedule(
  'limpiar-tv-pairings', '0 4 * * *',
  $$ select public.limpiar_tv_pairings(); $$
);
```

---

## Cómo queda para el usuario

1. En el TV, pantalla de espera → **Activar este televisor** → sale un código.
2. En el teléfono, **Ajustes › Vincular televisor** → lo escribe.
3. El TV se vincula solo, sin tocar el mando.

Para quitarlo: misma pantalla del teléfono, la ✕ del televisor.

**Transmitir sigue siendo gratis.** Esto solo abre el modo autónomo; quien solo
transmite desde el móvil no se entera de que existe.

## Decisiones que conviene no deshacer

**El tope son 2 televisores** (`MAX_TVS` en `index.ts`). Es lo que de verdad
frena que se preste el acceso — mucho más que la caducidad del código: pasarle
el código a un amigo te cuesta una de tus dos plazas. Volver a vincular el
mismo aparato no gasta plaza.

**El código caduca a los 10 minutos** y aguanta 8 intentos fallidos. Con un
alfabeto de 29 caracteres sin ambigüedades (fuera O/0, I/1, S/5, B/8) y ese
tope de intentos, adivinarlo a ciegas no es viable.

**El premium se comprueba en el servidor.** Si el teléfono mandara un
`esPremium: true` y nos fiáramos, la suscripción sería una casilla que
cualquiera marca.

**Un fallo de red no revoca nada.** `validarToken()` devuelve `null` cuando no
pudo preguntar, que no es lo mismo que "no tienes derecho". Cortarle el acceso
a un usuario de pago porque su wifi va mal sería peor que el problema que esto
resuelve.
