#!/bin/bash
# ============================================================================
#  Precarga nocturna de la cache — bump_comba
#  Instalar en: /usr/local/bin/precarga.sh   (cron a las 3 AM)
# ============================================================================
#
#  QUE HACE
#  --------
#  Descarga a traves del propio nginx los primeros MB de los estrenos mas
#  recientes. Como pasa por la cache, esos trozos quedan guardados en disco y
#  al dia siguiente los usuarios los reciben del VPS sin tocar al proveedor.
#
#  POR QUE EL ARRANQUE Y NO LA PELICULA ENTERA
#  -------------------------------------------
#  Con pocas conexiones y 70 GB de cache no alcanza para peliculas completas.
#  Los primeros minutos son donde mas duele la espera (es cuando el usuario
#  decide si "no carga"), y con ese margen el resto alcanza a bajar mientras
#  se reproduce.
#
#  CONFIGURACION: se lee de /etc/precarga.conf (ver INSTALAR)
# ============================================================================

CONF=/etc/precarga.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${HOST:=http://127.0.0.1}"          # nginx local (para que cachee)
: "${API_HOST:=http://red4tv.lat}"     # de donde se lee el catalogo
: "${USUARIO:?falta USUARIO en $CONF}"
: "${CLAVE:?falta CLAVE en $CONF}"
: "${CANTIDAD:=30}"                    # cuantos estrenos precargar
: "${MB:=250}"                         # MB por pelicula
: "${PARALELO:=2}"                     # conexiones simultaneas (dejar 1 libre)
: "${MAX_DISCO:=85}"                   # % de disco a partir del cual no sigue
: "${MAX_HORAS:=4}"                    # corte de seguridad

LOG=/var/log/precarga.log
FIN=$(( $(date +%s) + MAX_HORAS*3600 ))
BYTES=$(( MB * 1024 * 1024 - 1 ))

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

disco_ok() {
  local u
  u=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  [ "$u" -lt "$MAX_DISCO" ]
}

log "=== inicio (cantidad=$CANTIDAD mb=$MB paralelo=$PARALELO) ==="

if ! disco_ok; then
  log "disco por encima del ${MAX_DISCO}% — no se precarga nada"
  exit 0
fi

# ── 1) Traer el catalogo y quedarse con los mas recientes ──────────────────
LISTA=$(mktemp)
if ! curl -s -m 120 \
    "${API_HOST}/player_api.php?username=${USUARIO}&password=${CLAVE}&action=get_vod_streams" \
    -o "$LISTA"; then
  log "ERROR: no se pudo leer el catalogo"
  rm -f "$LISTA"; exit 1
fi

# Ordena por fecha de alta (campo `added`) descendente y saca "id.ext"
IDS=$(python3 - "$LISTA" "$CANTIDAD" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception as e:
    sys.exit(0)
n = int(sys.argv[2])
def added(x):
    try: return int(x.get('added') or 0)
    except: return 0
vod = [x for x in d if x.get('stream_id')]
vod.sort(key=added, reverse=True)
for x in vod[:n]:
    print(f"{x['stream_id']}.{x.get('container_extension') or 'mkv'}")
PY
)
rm -f "$LISTA"

TOTAL=$(echo "$IDS" | grep -c . || true)
if [ "$TOTAL" -eq 0 ]; then
  log "ERROR: catalogo vacio o ilegible"
  exit 1
fi
log "catalogo leido: $TOTAL titulos a precargar"

# ── 2) Descargar el arranque de cada uno (a traves de nginx = se cachea) ────
# Se descarga en trozos de 10 MB, NO en un unico bloque grande.
#
# Motivo: este proveedor trunca las respuestas cuando esta cargado — se
# comprobo pidiendo 1 MB y recibiendo 393 KB / 626 KB, cortando en un punto
# distinto cada vez. Con un bloque de 250 MB, una truncadura temprana pierde
# todo el trabajo; con trozos de 10 MB solo se pierde (y se reintenta) ese
# trozo. Ademas se verifican los BYTES recibidos: un 206 con cuerpo vacio es
# un fallo, aunque el codigo HTTP diga que todo bien.
TROZO=$(( 10 * 1024 * 1024 ))

precargar_uno() {
  local item="$1"
  local url="${HOST}/movie/${USUARIO}/${CLAVE}/${item}"
  local desde=0 total=0 intento code size esperado fallos=0

  while [ "$desde" -le "$BYTES" ]; do
    local hasta=$(( desde + TROZO - 1 ))
    [ "$hasta" -gt "$BYTES" ] && hasta=$BYTES
    esperado=$(( hasta - desde + 1 ))

    size=0
    for intento in 1 2 3; do
      read -r code size < <(
        curl -s -m 180 -o /dev/null \
             -H "Range: bytes=${desde}-${hasta}" \
             -w '%{http_code} %{size_download}' \
             "$url"
      )
      # Solo cuenta como bueno si llegaron TODOS los bytes pedidos.
      [ "$size" -ge "$esperado" ] && break
      sleep $(( intento * 3 ))
    done

    if [ "$size" -lt "$esperado" ]; then
      fallos=$((fallos+1))
      # Tres trozos seguidos fallando = el origen no esta dando mas.
      # Se abandona este titulo y se sigue con el proximo.
      if [ "$fallos" -ge 3 ]; then
        log "  PARCIAL $item ($(( total / 1024 / 1024 )) MB) — origen cortando"
        return
      fi
    else
      fallos=0
    fi

    total=$(( total + size ))
    desde=$(( hasta + 1 ))
  done

  if [ "$total" -eq 0 ]; then
    log "  FALLA $item — 0 bytes (HTTP $code)"
  else
    log "  ok    $item  ($(( total / 1024 / 1024 )) MB)"
  fi
}
export -f precargar_uno log
export HOST USUARIO CLAVE BYTES LOG TROZO

HECHOS=0
for item in $IDS; do
  # Cortes de seguridad
  if [ "$(date +%s)" -ge "$FIN" ]; then
    log "corte por tiempo (${MAX_HORAS}h)"; break
  fi
  if ! disco_ok; then
    log "corte por disco (>=${MAX_DISCO}%)"; break
  fi

  precargar_uno "$item" &

  HECHOS=$((HECHOS+1))
  # Limitar la concurrencia para no agotar las conexiones del proveedor
  while [ "$(jobs -rp | wc -l)" -ge "$PARALELO" ]; do sleep 2; done
done
wait

USO=$(df --output=pcent / | tail -1 | tr -d ' ')
CACHE=$(du -sh /var/cache/vod 2>/dev/null | cut -f1)
log "=== fin: $HECHOS titulos | cache=$CACHE | disco=$USO ==="
