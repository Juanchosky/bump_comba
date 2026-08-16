# Poner en marcha el proxy con caché

VPS: Contabo Cloud VPS 4 — `217.216.80.212` (US-east)

---

## 1. Instalar nginx y crear la caché

Conectate por SSH (`ssh root@217.216.80.212`) y pegá:

```bash
apt update && apt install -y nginx
mkdir -p /var/cache/vod /var/cache/vodapi
chown -R www-data:www-data /var/cache/vod /var/cache/vodapi
```

## 2. Subir la configuración

Copiá `nginx-cache-vod.conf` a `/etc/nginx/conf.d/vod.conf` y validá:

```bash
nginx -t && systemctl reload nginx
```

Si `nginx -t` da error, **no recargues** — mandame el mensaje.

## 3. Probar que funciona

Con una película real del catálogo (cambiá el ID por uno tuyo):

```bash
curl -s -o /dev/null -D - -H "Range: bytes=0-1048575" "http://217.216.80.212/movie/USUARIO/CLAVE/759711.mkv" | grep -iE "^HTTP|x-cache"
```

Qué tenés que ver:

- **1ra vez:** `HTTP/1.1 206` y `X-Cache: MISS` (lo fue a buscar al proveedor)
- **2da vez:** `HTTP/1.1 206` y `X-Cache: HIT` ← **esto es lo que importa**

Si la segunda da `HIT`, la caché funciona y ese trozo ya no consume conexiones
del proveedor nunca más.

## 4. Apuntar la app al VPS

En la app, cambiá el host de la fuente Xtream:

| Antes | Después |
|---|---|
| `http://red4tv.lat` | `http://217.216.80.212` |

Usuario y contraseña siguen igual. La app arma las URLs sola
(`/movie/usuario/clave/ID.mkv`), así que no hay que tocar nada más.

> Probalo primero en **un solo dispositivo**. Si algo sale mal, volvés el host
> a `red4tv.lat` y todo sigue como antes — no hay cambio irreversible.

## 5. Vigilar el disco

La caché crece hasta 80 GB y después nginx borra lo menos usado. Para mirar:

```bash
du -sh /var/cache/vod
df -h /
```

---

## Después: subir el paralelismo cuando compres más conexiones

La app ahora abre **1 sola conexión por reproducción** (antes hasta 4, por eso
un único usuario te agotaba la línea de 3).

Cuando contrates más conexiones podés subirlo **sin publicar una app nueva**.
En Supabase, tabla `sys_config`, insertá:

| columna | valor |
|---|---|
| `key` | `turbo_max_parallel` |
| `value` | `2` (o el número que corresponda) |
| `is_active` | `true` |

Guía para elegir el número:

| Conexiones contratadas | Espectadores simultáneos esperados | Valor sugerido |
|---|---|---|
| 3 | 3 o más | `1` |
| 10 | ~10 | `1` |
| 20 | ~10 | `2` |
| 50 | ~12 | `3` o `4` |

La regla es: **conexiones ÷ espectadores simultáneos**. Ante la duda, dejalo
en `1` — con caché en el VPS la velocidad la da el disco del VPS, no el
paralelismo contra el proveedor.

> Con `turbo_max_parallel = 1` el modo Turbo queda desactivado a propósito:
> trocear en peticiones de 1 MB dispara un redirect `302` por cada trozo
> (~2000 peticiones en una película de 2 GB) sin ganar velocidad alguna.

---

## Idea para más adelante: precargar de madrugada

Con pocas conexiones, conviene llenar la caché cuando nadie mira. Un cron a
las 3 AM que recorra los estrenos más vistos y descargue los primeros ~300 MB
de cada uno deja esos títulos listos para el día siguiente sin tocar al
proveedor en hora pico.

Decime si lo querés y te armo el script.
