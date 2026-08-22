#!/bin/bash
# ============================================================================
#  Generador del catalogo pre-horneado — bump_comba
#  Instalar en: /usr/local/bin/catalogo.sh   (cron cada hora)
# ============================================================================
#
#  QUE HACE
#  --------
#  Baja del panel las tres listas (peliculas, series, canales), les quita todo
#  lo que la app no usa y deja tres archivos estaticos comprimidos que nginx
#  sirve sin tocar al proveedor.
#
#  POR QUE
#  -------
#  Medido contra red4tv.lat el 2026-08-22: la app pide hoy 22.48 MB repartidos
#  en siete peticiones y tarda 21.3 s contra el panel (8.6 s con el cache de
#  player_api.php). El parser de la app solo lee SEIS campos de cada registro
#  (ver parseVodStreamsInBackground en lib/services/xtream_service.dart); todo
#  lo demas —added, rating, custom_sid, direct_source, tmdb_id, num...— se tira
#  al parsear. Podando a esos campos y comprimiendo, esos 22.48 MB quedan en
#  1.21 MB: -94.6%, medido al byte.
#
#  LA CLAVE ESTA EN EL ETAG
#  ------------------------
#  El archivo solo se REEMPLAZA si su contenido cambio de verdad. Si el panel
#  devuelve lo mismo, no se toca nada: la fecha de modificacion queda igual,
#  nginx sigue emitiendo el mismo ETag y los usuarios reciben un 304 de ~200
#  bytes en vez de redescargar el catalogo.
#
#  Sin esto, reconstruir cada hora obligaria a TODOS los usuarios a bajar
#  1.21 MB cada hora aunque no hubiera ni una pelicula nueva. Con 1000 usuarios
#  esa es la diferencia entre ~1.2 GB/dia y ~29 GB/dia sobre un puerto de
#  200 Mbit/s que ademas tiene que servir el video. Por eso la salida es
#  DETERMINISTA (todo ordenado, sin fechas dentro): dos corridas con el mismo
#  catalogo producen archivos byte a byte identicos.
#
#  NO LLEVA CREDENCIALES DENTRO
#  ----------------------------
#  Se guarda el stream_id y la extension, no la URL. La app arma
#  `$host/movie/$user/$pass/$id.$ext` en el telefono con sus propias
#  credenciales. El archivo servido es el mismo para todos y no expone nada.
#
#  CONFIGURACION: reusa /etc/precarga.conf (mismas credenciales)
# ============================================================================

set -u

CONF=/etc/precarga.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${API_HOST:=http://red4tv.lat}"
: "${USUARIO:?falta USUARIO en $CONF}"
: "${CLAVE:?falta CLAVE en $CONF}"
: "${SALIDA:=/var/www/catalogo}"
: "${TIMEOUT:=180}"
# Si una lista viene con menos del N% de items que la ya publicada, se
# considera respuesta truncada y NO se reemplaza. El panel devuelve respuestas
# cortadas cuando esta cargado (ya comprobado en precarga.sh).
: "${MIN_PORCENTAJE:=60}"

LOG=/var/log/catalogo.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

mkdir -p "$SALIDA" || { log "ERROR: no se pudo crear $SALIDA"; exit 1; }

log "=== inicio ==="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PODADOR="$TMP/podar.py"
cat > "$PODADOR" <<'FIN_PY'
import json, sys

archivo_items, archivo_cats, tipo, archivo_salida = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])

def cargar(ruta):
    with open(ruta, encoding='utf-8', errors='replace') as f:
        d = json.load(f)
    if isinstance(d, dict):
        d = list(d.values())
    return d if isinstance(d, list) else []

try:
    crudos = cargar(archivo_items)
except Exception as e:
    sys.stderr.write('ERROR_PARSEO %s' % e)
    sys.exit(2)

try:
    cats_crudas = cargar(archivo_cats)
except Exception:
    cats_crudas = []

categorias = {}
for c in cats_crudas:
    if not isinstance(c, dict):
        continue
    cid = c.get('category_id')
    nom = c.get('category_name')
    if cid is not None and nom:
        categorias[str(cid)] = str(nom)

# El id que usa la app cambia segun el tipo: las series se identifican por
# series_id (la app guarda ese id como `url` y despues pide los episodios),
# peliculas y canales por stream_id.
campo_id = 'series_id' if tipo == 'series' else 'stream_id'
# El logo tambien: en series viene en `cover`, en VOD puede venir en
# cualquiera de los dos. Mismo orden de preferencia que el parser de la app.
campos_logo = ('cover', 'stream_icon') if tipo == 'series' else ('stream_icon', 'cover')

items = []
vistos = set()
for x in crudos:
    if not isinstance(x, dict):
        continue
    ident = x.get(campo_id)
    if ident is None:
        continue
    ident = str(ident)
    if ident in vistos:
        continue
    vistos.add(ident)

    # Claves cortas: el nombre del campo se repite en CADA uno de los ~25.000
    # registros, asi que 'container_extension' vs 'e' pesa de verdad. Los
    # campos vacios se omiten en vez de escribirse como null.
    fila = {'i': ident, 'n': str(x.get('name') or 'Sin nombre')}

    if tipo != 'series':
        ext = x.get('container_extension')
        if ext:
            fila['e'] = str(ext)

    cid = x.get('category_id')
    if cid is not None:
        fila['c'] = str(cid)

    for campo in campos_logo:
        v = x.get(campo)
        if v and str(v).strip():
            fila['l'] = str(v).strip()
            break

    if tipo == 'vod':
        d = x.get('duration') or x.get('duration_secs')
        if d:
            fila['d'] = str(d)

    items.append(fila)

# Orden estable por id numerico cuando se puede. Sin esto el panel podria
# devolver el mismo catalogo en otro orden y el archivo cambiaria sin que haya
# contenido nuevo, invalidando el ETag para todos los usuarios.
def clave(f):
    try:
        return (0, int(f['i']), '')
    except (ValueError, TypeError):
        return (1, 0, f['i'])

items.sort(key=clave)

salida = {'v': 1, 'categorias': categorias, 'items': items}

# El archivo se escribe AQUI, con la codificacion fijada a mano, en vez de
# mandarlo por stdout y redirigirlo desde el shell.
#
# Motivo: la codificacion de stdout la elige Python segun el locale del
# entorno. Cron corre con un entorno minimo (normalmente sin LANG), asi que
# ahi no es UTF-8 y los nombres con acento se escribian mal o reventaban con
# UnicodeEncodeError. Comprobado: "Accion" salia como 0xf3 (cp1252) en vez de
# 0xc3 0xb3 (UTF-8), el archivo quedaba ilegible para la app, y de rebote la
# guarda contra respuestas truncadas se saltaba porque tampoco podia leer el
# catalogo ya publicado para compararlo.
#
# sort_keys + separadores compactos: misma entrada -> mismos bytes, siempre.
with open(archivo_salida, 'w', encoding='utf-8', newline='') as f:
    json.dump(salida, f, ensure_ascii=False, sort_keys=True,
              separators=(',', ':'))

sys.stdout.write(str(len(items)))
FIN_PY

CONTADOR="$TMP/contar.py"
cat > "$CONTADOR" <<'FIN_PY'
import json, sys
# -1 = el archivo esta pero no se puede leer. Distinto de 0 = no hay archivo.
# Confundir ambos casos hacia que un catalogo publicado corrupto se tratara
# como "no hay nada publicado" y desactivara la guarda contra truncados.
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(len(json.load(f).get('items', [])))
except Exception:
    print(-1)
FIN_PY

contar_publicado() {
  local archivo="$1"
  if [ ! -f "$archivo" ]; then echo 0; return; fi
  python3 "$CONTADOR" "$archivo" 2>/dev/null || echo 0
}

generar() {
  local nombre="$1" accion_items="$2" accion_cats="$3" tipo="$4"

  local f_items="$TMP/${nombre}_items.json"
  local f_cats="$TMP/${nombre}_cats.json"
  local f_out="$TMP/${nombre}.json"
  local f_err="$TMP/${nombre}.err"

  local base="${API_HOST}/player_api.php?username=${USUARIO}&password=${CLAVE}"

  if ! curl -s -f -m "$TIMEOUT" --compressed "${base}&action=${accion_items}" -o "$f_items"; then
    log "  $nombre: ERROR bajando $accion_items — se conserva lo publicado"
    return 1
  fi
  if ! curl -s -f -m 60 --compressed "${base}&action=${accion_cats}" -o "$f_cats"; then
    log "  $nombre: aviso — no se pudieron bajar las categorias, quedan vacias"
    echo '[]' > "$f_cats"
  fi

  local crudo
  crudo=$(stat -c %s "$f_items" 2>/dev/null || echo 0)

  local n_items
  if ! n_items=$(python3 "$PODADOR" "$f_items" "$f_cats" "$tipo" "$f_out" 2>"$f_err"); then
    log "  $nombre: ERROR al podar ($(cat "$f_err" 2>/dev/null)) — se conserva lo publicado"
    return 1
  fi
  case "$n_items" in
    ''|*[!0-9]*) n_items=0 ;;
  esac

  if [ "$n_items" -eq 0 ]; then
    log "  $nombre: 0 items — se conserva lo publicado"
    return 1
  fi

  # ── Guarda contra respuestas truncadas ───────────────────────────────────
  # El proveedor corta respuestas cuando esta cargado. Publicar un catalogo a
  # medias le borra a todos los usuarios la mitad del contenido hasta la
  # proxima corrida, asi que ante la duda se prefiere lo viejo y completo.
  local publicado minimo
  publicado=$(contar_publicado "$SALIDA/${nombre}.json")
  if [ "$publicado" -lt 0 ]; then
    log "  $nombre: el catalogo publicado esta ilegible — se reemplaza sin comparar"
  elif [ "$publicado" -gt 0 ]; then
    minimo=$(( publicado * MIN_PORCENTAJE / 100 ))
    if [ "$n_items" -lt "$minimo" ]; then
      log "  $nombre: SOSPECHOSO ${n_items} items vs ${publicado} publicados (<${MIN_PORCENTAJE}%) — se conserva lo publicado"
      return 1
    fi
  fi

  # ── Solo se reemplaza si el contenido cambio (ver nota del ETag arriba) ──
  local hash_nuevo hash_viejo=""
  hash_nuevo=$(sha256sum "$f_out" | cut -d' ' -f1)
  if [ -f "$SALIDA/${nombre}.json" ]; then
    hash_viejo=$(sha256sum "$SALIDA/${nombre}.json" | cut -d' ' -f1)
  fi

  local gz_size
  if [ "$hash_nuevo" = "$hash_viejo" ]; then
    log "  $nombre: sin cambios ($n_items items) — no se toca, ETag intacto"
    return 0
  fi

  if ! gzip -9 -c "$f_out" > "$TMP/${nombre}.json.gz"; then
    log "  $nombre: ERROR al comprimir — se conserva lo publicado"
    return 1
  fi

  # mv dentro del mismo sistema de archivos es atomico: nginx nunca sirve un
  # archivo a medio escribir. El .gz va PRIMERO para que gzip_static jamas
  # quede apuntando a una version mas vieja que el .json.
  mv -f "$TMP/${nombre}.json.gz" "$SALIDA/${nombre}.json.gz" || return 1
  mv -f "$f_out"                 "$SALIDA/${nombre}.json"    || return 1
  chmod 644 "$SALIDA/${nombre}.json" "$SALIDA/${nombre}.json.gz"

  gz_size=$(stat -c %s "$SALIDA/${nombre}.json.gz" 2>/dev/null || echo 0)
  log "  $nombre: ACTUALIZADO $n_items items | crudo $(( crudo / 1024 ))KB -> gz $(( gz_size / 1024 ))KB"
  return 0
}

fallos=0
generar vod    get_vod_streams  get_vod_categories    vod    || fallos=$((fallos+1))
generar series get_series       get_series_categories series || fallos=$((fallos+1))
generar live   get_live_streams get_live_categories   live   || fallos=$((fallos+1))

total_gz=0
for n in vod series live; do
  s=$(stat -c %s "$SALIDA/${n}.json.gz" 2>/dev/null || echo 0)
  total_gz=$(( total_gz + s ))
done

log "=== fin: $((3 - fallos))/3 listas ok | total servido $(( total_gz / 1024 ))KB ==="

if [ "$fallos" -eq 3 ]; then exit 1; fi
exit 0
