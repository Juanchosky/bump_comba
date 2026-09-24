#!/bin/bash
# ============================================================================
#  Volcado de configuración (sys_config + m3u_load_balancer) — bump_comba
#  Instalar en: /usr/local/bin/config.sh   (cron cada 5 min)
# ============================================================================
#
#  QUE HACE
#  --------
#  Baja las tablas `sys_config` y `m3u_load_balancer` de Supabase y las deja
#  como JSON estáticos que nginx sirve desde el VPS. La app las lee de aquí
#  en vez de pedírselas a Supabase.
#
#  POR QUE
#  -------
#  Cuando Supabase se desactiva (402 en todo), la app pierde acceso a la
#  configuración remota y al load balancer. Servirlos desde el VPS elimina
#  esa dependencia: el único que consulta Supabase es este script.
#
#  Son tablas pequeñas (~1-5 KB cada una). Sin paginación ni sondeo: se bajan
#  enteras y se publican solo si el contenido cambió (ETag estable).
#
#  CONFIGURACION: /etc/bd.conf (misma que bd.sh)
# ============================================================================

set -u

CONF=/etc/bd.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${SUPABASE_URL:?falta SUPABASE_URL en $CONF}"
: "${SUPABASE_KEY:?falta SUPABASE_KEY en $CONF}"
: "${SALIDA:=/var/www/catalogo}"
: "${TIMEOUT:=30}"

LOG=/var/log/config-volcado.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

mkdir -p "$SALIDA" || { log "ERROR: no se pudo crear $SALIDA"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REST="${SUPABASE_URL%/}/rest/v1"

api() {
  curl -s -m "$TIMEOUT" --compressed \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    "$@"
}

# ── Función genérica: volcar tabla y publicar si cambió ─────────────────────
volcar_tabla() {
  local tabla="$1"
  local filtro="$2"
  local columnas="$3"
  local nombre="$4"

  local f_tmp="$TMP/${nombre}.json"
  local f_pub="$SALIDA/${nombre}.json"

  if ! api -o "$f_tmp" "${REST}/${tabla}?select=${columnas}&${filtro}"; then
    log "ERROR: no se pudo bajar ${tabla}"
    return 1
  fi

  # Validar que sea JSON válido y no esté vacío
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f_tmp" 2>/dev/null; then
    log "ERROR: ${tabla} no es JSON válido"
    return 1
  fi

  # Normalizar: ordenar claves para salida determinista (ETag estable)
  python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    datos = json.load(f)
if not isinstance(datos, list):
    datos = []
datos = [{k: v for k, v in x.items() if v is not None} for x in datos]
with open(sys.argv[2], 'w', encoding='utf-8', newline='') as f:
    json.dump(datos, f, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
" "$f_tmp" "$f_tmp.norm" || { log "ERROR al normalizar ${tabla}"; return 1; }
  mv -f "$f_tmp.norm" "$f_tmp"

  # Solo publicar si cambió
  local hash_nuevo hash_viejo=""
  hash_nuevo=$(sha256sum "$f_tmp" | cut -d' ' -f1)
  [ -f "$f_pub" ] && hash_viejo=$(sha256sum "$f_pub" | cut -d' ' -f1)

  if [ "$hash_nuevo" = "$hash_viejo" ]; then
    return 0
  fi

  # Comprimir y publicar
  gzip -9 -c "$f_tmp" > "$TMP/${nombre}.json.gz" || return 1
  mv -f "$TMP/${nombre}.json.gz" "$f_pub.gz" || return 1
  mv -f "$f_tmp"                 "$f_pub"     || return 1
  chmod 644 "$f_pub" "$f_pub.gz"

  local tam
  tam=$(stat -c %s "$f_pub" 2>/dev/null || echo 0)
  log "ACTUALIZADO ${tabla} -> ${nombre}.json (${tam} bytes)"
}

# ── sys_config ──────────────────────────────────────────────────────────────
volcar_tabla \
  "sys_config" \
  "is_active=eq.true" \
  "key,value,is_active" \
  "sys_config"

# ── m3u_load_balancer ───────────────────────────────────────────────────────
volcar_tabla \
  "m3u_load_balancer" \
  "is_active=eq.true" \
  "id,key,value,current_connections,max_connections,type,username,password" \
  "load_balancer"

exit 0
