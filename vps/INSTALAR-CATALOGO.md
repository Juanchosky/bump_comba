# Catálogo pre-horneado

Reemplaza las siete peticiones que la app le hace al panel en cada arranque
por **una sola** a un archivo estático que vive en tu VPS.

**Medido contra red4tv.lat el 2026-08-22:**

|            | Hoy                                       | Con el snapshot    |
| ---------- | ----------------------------------------- | ------------------ |
| Peticiones | 7                                         | 1 (o 3, ver abajo) |
| Bytes      | 22.48 MB                                  | 1.21 MB            |
| Tiempo     | 21.3 s contra el panel / 8.6 s por el VPS | ~1 s               |

El ahorro no sale sólo del gzip: sale de **podar**. El parser de la app lee
seis campos de cada película (`stream_id`, `container_extension`,
`category_id`, `name`, `stream_icon`, `duration`) y tira todo lo demás —
`added`, `rating`, `custom_sid`, `direct_source`, `tmdb_id`, `plot`, `cast`…
El script guarda sólo esos seis, con nombres de clave de una letra.

---

## 1. Subir el script

Desde tu PC, una línea:

```bash
scp "C:\Users\Juan Arrieta\Downloads\bump_comba\vps\catalogo.sh" root@217.216.80.212:/usr/local/bin/catalogo.sh
```

## 2. Preparar el VPS

En el VPS (`ssh root@217.216.80.212`). No hace falta configurar credenciales:
el script **reusa `/etc/precarga.conf`**, que ya creaste para la precarga.

```bash
chmod +x /usr/local/bin/catalogo.sh
mkdir -p /var/www/catalogo
```

Comprobá que tu nginx trae el módulo que sirve los `.gz` ya comprimidos:

```bash
nginx -V 2>&1 | grep -o with-http_gzip_static_module
```

Tiene que imprimir `with-http_gzip_static_module`. Si no imprime nada, instalá
`nginx-extras` (`apt install nginx-extras`) — sin ese módulo nginx recomprime
5.6 MB en cada petición y te quema la CPU que necesitás para el video.

## 3. Primera corrida

```bash
/usr/local/bin/catalogo.sh; cat /var/log/catalogo.log
```

Tenés que ver algo así:

```
=== inicio ===
  vod: ACTUALIZADO 25431 items | crudo 18333KB -> gz 921KB
  series: ACTUALIZADO 1204 items | crudo 3143KB -> gz 155KB
  live: ACTUALIZADO 3890 items | crudo 1548KB -> gz 161KB
=== fin: 3/3 listas ok | total servido 1237KB ===
```

## 4. Comprobar que es determinista

Este paso **no te lo saltes**: es lo que hace que el ahorro de tráfico sea
real. Corré el script otra vez, seguido:

```bash
/usr/local/bin/catalogo.sh; tail -4 /var/log/catalogo.log
```

Tiene que decir `sin cambios ... ETag intacto` en las tres listas. Si dice
`ACTUALIZADO` dos veces seguidas sin que haya entrado contenido nuevo, cada
usuario redescargaría 1.21 MB **cada hora** en vez de una vez al día.

Mirá el número de items de las dos corridas:

- **Mismo número de items pero dice `ACTUALIZADO` las dos veces** → el panel te
  está devolviendo el mismo catálogo en distinto orden. El script respeta el
  orden del panel a propósito (ver abajo), así que ahí hay que ordenar por
  `added` descendente en `catalogo.sh`. Avisame y lo cambio.
- **Distinto número de items** → entró contenido nuevo entre las dos corridas.
  Es normal, probá otra vez.

## 5. Publicarlo en nginx

Copiá el bloque `location /catalogo/` de `vps/nginx-cache-vod.conf` (sección 3)
a tu `/etc/nginx/conf.d/vod.conf`, y recargá:

```bash
nginx -t && systemctl reload nginx
```

Probá que sirve comprimido y que responde 304 la segunda vez:

```bash
curl -s -o /dev/null -w "%{http_code} %{size_download} bytes\n" -H "Accept-Encoding: gzip" http://217.216.80.212/catalogo/vod.json
```

Sacá el ETag y volvé a pedir con él:

```bash
ETAG=$(curl -sI -H "Accept-Encoding: gzip" http://217.216.80.212/catalogo/vod.json | grep -i etag | tr -d '\r' | cut -d' ' -f2)
curl -s -o /dev/null -w "%{http_code} %{size_download} bytes\n" -H "If-None-Match: $ETAG" -H "Accept-Encoding: gzip" http://217.216.80.212/catalogo/vod.json
```

La primera línea tiene que dar `200` con ~940000 bytes. La segunda, **`304` con
0 bytes**. Si la segunda también da 200, el ETag no está funcionando y no hay
ahorro.

## 6. Programarlo cada hora

```bash
crontab -e
```

Agregá:

```
17 * * * * /usr/local/bin/catalogo.sh >/dev/null 2>&1
```

El minuto 17 y no el 0 es a propósito: el minuto en punto es cuando corren los
cron de medio mundo y el panel del proveedor está más cargado.

---

## Qué hace si algo sale mal

El script **nunca publica un catálogo peor que el que ya está**:

- Si el panel no responde o da error → conserva lo publicado y lo anota.
- Si el JSON viene ilegible → conserva lo publicado.
- Si vienen **menos del 60 %** de los ítems que ya hay publicados → asume que
  el proveedor cortó la respuesta a medias (ya pasa con la precarga) y conserva
  lo publicado. Ajustable con `MIN_PORCENTAJE` en `/etc/precarga.conf`.
- Si sólo falla una de las tres listas, las otras dos se actualizan igual.

Los archivos se mueven con `mv` dentro del mismo disco, que es atómico: nginx
nunca sirve un archivo a medio escribir.

## Qué NO hay adentro

**Credenciales, ninguna.** Se guarda `stream_id` y extensión, no la URL. La app
arma `$host/movie/$user/$pass/$id.$ext` en el teléfono con las credenciales del
usuario. Por eso el mismo archivo sirve para todos.

## Formato

Tres archivos, cada uno con su ETag propio: `vod.json`, `series.json`,
`live.json` (más su `.gz`). Separados a propósito — la lista de canales casi
nunca cambia y el VOD cambia a diario, así que un estreno nuevo no obliga a
redescargar los canales.

```json
{
  "v": 1,
  "categorias": { "42": "Acción", "9": "Terror" },
  "items": [
    {
      "i": "759216",
      "n": "Nombre",
      "e": "mkv",
      "c": "42",
      "l": "http://…/cover.jpg",
      "d": "1:45:00"
    }
  ]
}
```

`i`=id · `n`=nombre · `e`=extensión · `c`=id de categoría · `l`=logo · `d`=duración.
Los campos vacíos se omiten. En `series.json`, `i` es el `series_id` y no hay
`e` ni `d`.

`v` es la versión del formato, para que la app pueda rechazar un archivo de un
formato que no entiende.

## Los duplicados no siempre son duplicados

En Xtream un mismo `stream_id` aparece **una vez por cada categoría** en la que
el proveedor lo puso: son registros distintos, con el mismo id y distinto
`category_id`. El camino contra el panel no deduplica nada, así que esos
títulos salen en las dos (o tres) categorías donde el proveedor los listó.

Por eso el script deduplica por **(id, categoría)** y no por id a secas.
Descarta únicamente el registro repetido de verdad —mismo título, misma
categoría, dos veces— que la app mostraría duplicado.

Deduplicar solo por id borraba el título de su segunda categoría en adelante.
El log lo canta:

```
series: aviso — 22 registros repetidos descartados (mismo id Y misma categoria)
```

Si ese número es alto, mirálo: con la regla vieja eran contenidos que
desaparecían de una categoría.

## El orden de los items no se toca

Los items van **en el mismo orden en que los manda el panel**, y eso no es un
descuido: la app pinta cada categoría en el orden del archivo, igual que hace
con la respuesta del panel. Si aquí se reordena, el usuario ve otro orden que
antes.

Ya pasó una vez: una versión de este script ordenaba por `stream_id`
ascendente. Como el id más bajo es el contenido más viejo, los estrenos
quedaban al final de cada categoría y había que bajar hasta el fondo para
verlos — daba toda la impresión de que faltaba contenido.

El precio es que la estabilidad del ETag depende de que el panel devuelva el
catálogo en un orden estable. Lo hace, y el paso 4 lo comprueba.
