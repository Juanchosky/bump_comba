# Volcado de la BD (custom_content) al VPS

Saca la lectura de `custom_content` de Supabase y la pasa al VPS, que tiene
tráfico ilimitado. Es lo que baja la egress de Supabase de ~6 GB/mes a casi
cero.

---

## Por qué

La app se bajaba las 21.000 filas de `custom_content` directo de Supabase.
Con 500-600 usuarios diarios, el ciclo de agosto de 2026 cerró en **6,4 GB
sobre una cuota de 5 GB (129%)**, con gracia hasta el 24/09/2026 y `402` en
todas las peticiones después de esa fecha.

Con esto, el único que le pregunta a Supabase es el VPS, y solo cuando algo
cambió.

---

## 1. Conseguir la clave anónima

En Supabase → **Project Settings → API Keys** → copiá la clave `anon` /
`publishable`. Es la misma que ya usa la app, así que no da más permisos de
los que ya están en la calle.

> No uses la `service_role`. El script solo lee, y esa clave se salta el RLS.

## 2. Crear el archivo de configuración

En el VPS (`ssh root@217.216.80.212`), cambiando `TU_CLAVE_ANON`:

```bash
cat > /etc/bd.conf <<'FIN'
SUPABASE_URL=https://inukqboqdvwtmmthjwrl.supabase.co
SUPABASE_KEY=TU_CLAVE_ANON
SALIDA=/var/www/catalogo
NOMBRE=bd
FORZAR_HORA=4
FIN
chmod 600 /etc/bd.conf
```

`chmod 600` deja el archivo legible solo por root: ahí va la clave.

## 3. Subir el script

Desde tu PC:

```bash
scp "C:\Users\Juan Arrieta\Downloads\bump_comba\vps\bd.sh" root@217.216.80.212:/usr/local/bin/bd.sh
```

En el VPS:

```bash
chmod +x /usr/local/bin/bd.sh
```

## 4. Primera corrida

```bash
/usr/local/bin/bd.sh; cat /var/log/bd.log
```

Tenés que ver algo así:

```
=== inicio (cambio detectado: '' -> '21012|2026-08-20T14:03:11') ===
=== fin: ACTUALIZADO 21012 filas | 3900KB -> gz 420KB ===
```

Si sale `SOSPECHOSO` o `ERROR`, pasámelo.

## 5. Comprobar que nginx lo sirve

**No hace falta tocar la config de nginx.** El bloque `location /catalogo/`
que ya existe sirve `/var/www/catalogo/` con `gzip_static on`, así que el
archivo queda disponible solo.

```bash
curl -s -o /dev/null -D - -H "Accept-Encoding: gzip" http://127.0.0.1/catalogo/bd.json | grep -iE "^HTTP|etag|content-length|content-encoding"
```

Tiene que dar `200`, `Content-Encoding: gzip` y un `ETag`. Anotá el ETag y
comprobá que la segunda visita cuesta ~200 bytes en vez de 420 KB:

```bash
ETAG=$(curl -sI -H "Accept-Encoding: gzip" http://127.0.0.1/catalogo/bd.json | grep -i etag | tr -d '\r' | cut -d' ' -f2); curl -s -o /dev/null -w "%{http_code} %{size_download} bytes\n" -H "If-None-Match: $ETAG" -H "Accept-Encoding: gzip" http://127.0.0.1/catalogo/bd.json
```

Tiene que decir `304 0 bytes`. **Ese 304 es el objetivo de todo esto**: los
usuarios que ya tienen el archivo no vuelven a bajarlo.

## 6. Programarlo cada 15 minutos

```bash
( crontab -l 2>/dev/null | grep -v '/usr/local/bin/bd.sh'; echo '*/15 * * * * /usr/local/bin/bd.sh' ) | crontab -
```

Verificá:

```bash
crontab -l
```

---

## Cómo se comporta

**Cada 15 minutos** hace un sondeo que pesa bytes: cuántas filas activas hay y
cuál es el `created_at` más reciente. Si los dos coinciden con la corrida
anterior, termina sin bajar nada y sin escribir en el log.

**Cuando entra o sale contenido**, el sondeo lo detecta y baja la tabla
completa (~3,9 MB, ~420 KB comprimida).

**Una vez al día**, a la hora de `FORZAR_HORA`, baja todo aunque el sondeo diga
que no cambió nada. Es para recoger *ediciones* sobre filas que ya existían —
cambiarle el título o la URL a algo ya subido no mueve ni el conteo ni la fecha
más reciente, así que el sondeo solo no las vería.

Coste total contra Supabase: unos **130 MB/mes** en el peor caso.

---

## Si subís contenido y querés verlo ya

El cron tarda hasta 15 minutos. Para forzarlo:

```bash
/usr/local/bin/bd.sh
```

Y en el teléfono, un refresco manual (`forceRefresh`) salta la caché local.

---

## Guardas que tiene

- **Volcado incompleto**: si trae menos del 60% de las filas ya publicadas, no
  reemplaza nada. Publicar media tabla le borraría a todos los usuarios la
  mitad del contenido.
- **ETag estable**: la salida es determinista (ordenada, sin fechas dentro), y
  el archivo solo se reemplaza si su contenido cambió de verdad. Sin esto,
  regenerar cada 15 min obligaría a todos a rebajar el archivo aunque no
  hubiera nada nuevo.
- **Escritura atómica**: el `.gz` se mueve antes que el `.json`, y los dos con
  `mv` dentro del mismo sistema de archivos. nginx nunca sirve un archivo a
  medio escribir.
- **Ante cualquier error, se conserva lo publicado.** El script prefiere datos
  viejos y completos antes que nuevos y rotos.

---

## Del lado de la app

`M3UService.fetchCustomContent()` ahora pide primero
`http://217.216.80.212/catalogo/bd.json` y **cae a Supabase si algo falla**.

Ese respaldo se queda ahí a propósito: si el VPS se cae, si el cron deja de
correr, o si todavía no instalaste esto, la app funciona igual que antes. O
sea que podés desplegar la app antes o después del script, en cualquier orden.

La caché local de `custom_content` está en **48 h** (`_customCacheDuration`),
separada de la del catálogo de Xtream a propósito: esta cuesta egress, la otra
no.
