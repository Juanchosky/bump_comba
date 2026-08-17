# ============================================================================
#  Precarga de TODAS las caratulas del catalogo
#  Instalar en: /usr/local/bin/precarga-imagenes.sh   (cron 4 AM)
# ============================================================================
#
#  POR QUE ESTO Y NO "REINTENTAR"
#  ------------------------------
#  Reintentar una caratula lenta no arregla nada: si tarda es porque el VPS no
#  la tiene y va a buscarla al origen, que es el que anda lento. Precargando el
#  catalogo COMPLETO no queda ninguna por buscar: todas salen del disco.
#
#  CABE ENTERO: ~25.600 caratulas x ~150 KB = ~3,8 GB, contra 10 GB asignados.
#  Se hace de madrugada, cuando el origen esta descargado.
# ============================================================================

CONF=/etc/precarga.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${API_HOST:=http://red4tv.lat}"
: "${VPS:=http://127.0.0.1}"
: "${USUARIO:?falta USUARIO en $CONF}"
: "${CLAVE:?falta CLAVE en $CONF}"
# Bajado de 8 a 4: con 8 el origen empezo a descartar conexiones y la corrida
# del 2026-08-16 murio a los 2.007 titulos de ~25.600. Mas lento por peticion
# pero termina muchas mas por noche, que es lo que importa.
# OJO: si /etc/precarga.conf define IMG_PARALELO, este default NO se aplica.
: "${IMG_PARALELO:=4}"
: "${IMG_MAX_DISCO:=88}"

LOG=/var/log/precarga.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

disco_ok() {
  local u; u=$(df --output=pcent / | tail -1 | tr -dc '0-9')
  [ "$u" -lt "$IMG_MAX_DISCO" ]
}

log "=== IMAGENES: inicio ==="
disco_ok || { log "IMAGENES: disco >= ${IMG_MAX_DISCO}% — se omite"; exit 0; }

# ── 1) Catalogo -> lista de rutas de caratula ──────────────────────────────
JSON=$(mktemp)
if ! curl -s -m 180 \
    "${API_HOST}/player_api.php?username=${USUARIO}&password=${CLAVE}&action=get_vod_streams" \
    -o "$JSON"; then
  log "IMAGENES: ERROR leyendo el catalogo"; rm -f "$JSON"; exit 1
fi

# Solo la RUTA (/images/xxx.jpg): es lo que entiende el location /images/ de
# nginx, sin depender de decodificar parametros.
RUTAS=$(python3 - "$JSON" <<'PY'
import json, sys
from urllib.parse import urlsplit
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(0)
vistas = set()
for x in d:
    u = (x.get('stream_icon') or '').strip()
    if not u.startswith('http'):
        continue
    p = urlsplit(u).path
    if p and p != '/' and p not in vistas:
        vistas.add(p)
        print(p)
PY
)
rm -f "$JSON"

TOTAL=$(echo "$RUTAS" | grep -c . || true)
[ "$TOTAL" -gt 0 ] || { log "IMAGENES: catalogo sin caratulas"; exit 1; }
log "IMAGENES: $TOTAL caratulas unicas a precargar"

# ── 2) Pedirlas a traves de nginx para que queden cacheadas ────────────────
OK=0; FALLO=0; N=0
for ruta in $RUTAS; do
  N=$((N+1))
  # Cada 500 se revisa el disco (chequear en cada imagen seria mucho df)
  if [ $((N % 500)) -eq 0 ] && ! disco_ok; then
    log "IMAGENES: corte por disco a las $N"; break
  fi

  {
    code=$(curl -s -m 25 -o /dev/null -w '%{http_code}' "${VPS}${ruta}")
    [ "$code" = "200" ] || echo "fallo" >> "/tmp/precarga_img_fallos.$$"
  } &

  while [ "$(jobs -rp | wc -l)" -ge "$IMG_PARALELO" ]; do sleep 0.2; done
done
wait

FALLO=$(wc -l < "/tmp/precarga_img_fallos.$$" 2>/dev/null || echo 0)
rm -f "/tmp/precarga_img_fallos.$$"
OK=$((N - FALLO))

CACHE=$(du -sh /var/cache/img 2>/dev/null | cut -f1)
USO=$(df --output=pcent / | tail -1 | tr -d ' ')
log "=== IMAGENES: fin — $OK ok / $FALLO fallidas de $N | cache=$CACHE | disco=$USO ==="
