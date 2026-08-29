#!/bin/bash
# ============================================================================
#  Volcado de la BD (custom_content de Supabase) — bump_comba
#  Instalar en: /usr/local/bin/bd.sh   (cron cada 15 min)
# ============================================================================
#
#  QUE HACE
#  --------
#  Baja la tabla `custom_content` de Supabase y la deja como un JSON estatico
#  que nginx sirve desde el VPS. La app pasa a pedirle el catalogo de la BD al
#  VPS en vez de a Supabase.
#
#  POR QUE
#  -------
#  La app se bajaba la tabla entera de Supabase con la caché local en 12 h.
#  Con 500-600 usuarios diarios eso cerro el ciclo de agosto de 2026 en
#  6,4 GB sobre una cuota de 5 GB (129%), con periodo de gracia hasta el
#  24/09/2026 y `402` en todas las peticiones despues de esa fecha.
#
#  Contabo da trafico ilimitado; Supabase cobra por GB. Moviendo la lectura al
#  VPS, el unico que consulta Supabase pasa a ser este script —una vez por
#  cambio— en vez de mil telefonos por dia.
#
#  LA CLAVE ESTA EN NO BAJAR NADA SI NADA CAMBIO
#  ---------------------------------------------
#  Si este script se bajara la tabla completa cada 15 minutos, serian 4,3 MB x
#  96 corridas = 413 MB/dia de egress: PEOR que el problema que viene a
#  resolver. Por eso cada corrida empieza con un SONDEO que pesa bytes:
#
#    - cuantas filas activas hay  (Content-Range, con `Prefer: count=exact`)
#    - cual es el `created_at` mas reciente
#
#  Si los dos coinciden con la corrida anterior, no se baja nada y se termina.
#  El volcado completo solo ocurre cuando entra o sale contenido.
#
#  El sondeo NO detecta ediciones sobre filas que ya existian (cambiarle el
#  titulo o la URL a algo ya subido). Para eso esta FORZAR_HORA: una vez al
#  dia se baja todo igual, cambie o no. Coste: ~4,3 MB/dia = 130 MB/mes.
#
#  LA OTRA CLAVE ESTA EN EL ETAG
#  -----------------------------
#  Igual que en catalogo.sh: el archivo solo se REEMPLAZA si su contenido
#  cambio de verdad. Si el volcado da lo mismo que lo publicado, no se toca
#  nada, la fecha de modificacion queda igual, nginx sigue emitiendo el mismo
#  ETag y los usuarios reciben un 304 de ~200 bytes en vez de redescargar.
#  Por eso la salida es DETERMINISTA: ordenada y sin fechas dentro.
#
#  CONFIGURACION: /etc/bd.conf (ver INSTALAR-BD.md)
# ============================================================================

set -u

CONF=/etc/bd.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${SUPABASE_URL:?falta SUPABASE_URL en $CONF}"
: "${SUPABASE_KEY:?falta SUPABASE_KEY en $CONF}"
: "${SALIDA:=/var/www/catalogo}"
: "${NOMBRE:=bd}"
: "${LOTE:=1000}"
: "${TIMEOUT:=120}"
# Si el volcado trae menos del N% de las filas ya publicadas, se considera
# respuesta incompleta y NO se reemplaza. Misma guarda que catalogo.sh.
: "${MIN_PORCENTAJE:=60}"
# Hora (0-23) en la que se baja todo aunque el sondeo diga que no cambio nada.
# Sirve para recoger ediciones sobre filas existentes.
: "${FORZAR_HORA:=4}"

ESTADO=/var/lib/bd-volcado.estado
# Fecha (YYYY-MM-DD) del ultimo volcado forzado. Ver la nota mas abajo.
FORZADO=/var/lib/bd-forzado.fecha
LOG=/var/log/bd.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

mkdir -p "$SALIDA" || { log "ERROR: no se pudo crear $SALIDA"; exit 1; }
mkdir -p "$(dirname "$ESTADO")" 2>/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REST="${SUPABASE_URL%/}/rest/v1/custom_content"
# Solo las columnas que la app parsea. `created_at` e `is_active` no se piden:
# la primera no se usa y la segunda ya viene filtrada.
COLUMNAS="id,title,title_aliases,video_url,thumbnail_url,type,parent_id,category,season,episode"

api() {
  curl -s -m "$TIMEOUT" --compressed \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    "$@"
}

# ── 1) SONDEO BARATO ────────────────────────────────────────────────────────
# `Range: 0-0` + `Prefer: count=exact` devuelve una sola fila y el total en la
# cabecera Content-Range. Son cientos de bytes, no megabytes.
cabeceras="$TMP/cab.txt"
if ! api -D "$cabeceras" -o /dev/null \
      -H "Range: 0-0" -H "Prefer: count=exact" \
      "${REST}?select=id&is_active=eq.true"; then
  log "ERROR: no se pudo sondear Supabase — se conserva lo publicado"
  exit 1
fi

filas=$(grep -i '^content-range:' "$cabeceras" | tr -d '\r' | sed 's#.*/##' | tr -d ' ')
case "${filas:-}" in
  ''|*[!0-9]*) log "ERROR: Content-Range ilegible — se conserva lo publicado"; exit 1 ;;
esac

ultimo=$(api "${REST}?select=created_at&is_active=eq.true&order=created_at.desc&limit=1" \
         | tr -d '[]"{}' | sed 's/created_at://')
[ -n "${ultimo:-}" ] || ultimo="sin_fecha"

huella="${filas}|${ultimo}"
huella_previa=""
[ -f "$ESTADO" ] && huella_previa=$(cat "$ESTADO" 2>/dev/null)

# ── El volcado forzado tiene que ser UNO POR DIA, no uno por corrida ────────
#
# El cron entra cada 15 min, asi que comprobar solo la hora hacia que durante
# toda la hora de FORZAR_HORA se bajara la tabla completa CUATRO veces (4:00,
# 4:15, 4:30, 4:45). Son 4 x 5,9 MB = 23,6 MB/dia = ~708 MB/mes de egress
# tirados: el 14% de la cuota entera de Supabase, gastado en bajar cuatro
# veces lo mismo.
#
# Con la fecha del ultimo forzado en disco, se fuerza una sola vez por dia:
# la primera corrida que caiga dentro de esa hora.
hora_actual=$(date +%-H)
hoy=$(date +%F)
forzado_previo=""
[ -f "$FORZADO" ] && forzado_previo=$(cat "$FORZADO" 2>/dev/null)

forzar=0
if [ "$hora_actual" = "$FORZAR_HORA" ] && [ "$forzado_previo" != "$hoy" ]; then
  forzar=1
fi

if [ "$huella" = "$huella_previa" ] && [ "$forzar" -eq 0 ] && [ -f "$SALIDA/${NOMBRE}.json" ]; then
  # Silencioso a proposito: esto corre cada 15 min y llenaria el log de ruido.
  exit 0
fi

if [ "$forzar" -eq 1 ]; then
  log "=== inicio (volcado diario forzado, ${filas} filas) ==="
else
  log "=== inicio (cambio detectado: '${huella_previa}' -> '${huella}') ==="
fi

# ── 2) VOLCADO COMPLETO, PAGINADO ───────────────────────────────────────────
# `order=id` es obligatorio: sin un orden estable, dos paginas consecutivas
# pueden repetir o saltarse filas.
crudo="$TMP/crudo.jsonl"
: > "$crudo"

desde=0
while [ "$desde" -lt "$filas" ]; do
  hasta=$(( desde + LOTE - 1 ))
  pagina="$TMP/pagina.json"
  if ! api -o "$pagina" \
        -H "Range: ${desde}-${hasta}" \
        "${REST}?select=${COLUMNAS}&is_active=eq.true&order=id"; then
    log "  ERROR bajando filas ${desde}-${hasta} — se conserva lo publicado"
    exit 1
  fi
  if [ ! -s "$pagina" ]; then
    log "  ERROR: pagina ${desde}-${hasta} vacia — se conserva lo publicado"
    exit 1
  fi
  cat "$pagina" >> "$crudo"
  echo >> "$crudo"
  desde=$(( hasta + 1 ))
done

# ── 3) NORMALIZAR A SALIDA DETERMINISTA ─────────────────────────────────────
NORMALIZADOR="$TMP/normalizar.py"
cat > "$NORMALIZADOR" <<'FIN_PY'
import json, sys

entrada, salida = sys.argv[1], sys.argv[2]

items = []
with open(entrada, 'r', encoding='utf-8', errors='replace') as f:
    contenido = f.read()

decoder = json.JSONDecoder(strict=False)
idx = 0
longitud = len(contenido)
while idx < longitud:
    while idx < longitud and contenido[idx].isspace():
        idx += 1
    if idx >= longitud:
        break
    try:
        obj, end_idx = decoder.raw_decode(contenido, idx)
        idx = end_idx
        if isinstance(obj, list):
            items.extend(x for x in obj if isinstance(x, dict))
        elif isinstance(obj, dict):
            items.append(obj)
    except Exception as e:
        sys.stderr.write('ERROR_PARSEO %s at idx %d' % (e, idx))
        sys.exit(2)

# Las filas sin id no le sirven a la app y romperian el enlace episodio->serie.
items = [x for x in items if x.get('id') is not None]

# Dedup por id: si una pagina se solapo con otra, aqui se corrige.
vistos = set()
unicos = []
for x in items:
    ident = str(x['id'])
    if ident in vistos:
        continue
    vistos.add(ident)
    unicos.append(x)
repetidos = len(items) - len(unicos)

# Las claves con valor nulo se van: `thumbnail_url` es null en practicamente
# todos los episodios (el poster lo pone la serie padre), y omitir la clave en
# vez de escribir `"thumbnail_url":null` ahorra ~20 bytes por fila. Con 20.000
# episodios son ~400 KB antes de comprimir. La app ya trata "clave ausente" y
# "clave en null" igual: usa `row['x']?.toString()`, que da null en ambos casos.
limpios = [{k: v for k, v in x.items() if v is not None} for x in unicos]

# Orden estable por id: misma entrada -> mismos bytes, siempre. Es lo que
# permite que el ETag no se mueva cuando no cambio nada (ver nota de arriba).
limpios.sort(key=lambda x: str(x.get('id')))

# sort_keys + separadores compactos, por lo mismo. Sin fechas ni contadores
# dentro del archivo: cualquier valor que cambie entre corridas rompe el ETag.
with open(salida, 'w', encoding='utf-8', newline='') as f:
    json.dump({'items': limpios}, f, ensure_ascii=False, sort_keys=True,
              separators=(',', ':'))

if repetidos:
    sys.stderr.write('%d filas repetidas descartadas' % repetidos)
sys.stdout.write(str(len(limpios)))
FIN_PY

CONTADOR="$TMP/contar.py"
cat > "$CONTADOR" <<'FIN_PY'
import json, sys
# -1 = el archivo esta pero no se puede leer. Distinto de 0 = no hay archivo.
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        print(len(json.load(f).get('items', [])))
except Exception:
    print(-1)
FIN_PY

f_out="$TMP/${NOMBRE}.json"
f_err="$TMP/${NOMBRE}.err"

if ! n_items=$(python3 "$NORMALIZADOR" "$crudo" "$f_out" 2>"$f_err"); then
  log "  ERROR al normalizar ($(cat "$f_err" 2>/dev/null)) — se conserva lo publicado"
  exit 1
fi
[ -s "$f_err" ] && log "  aviso — $(cat "$f_err")"

case "${n_items:-}" in
  ''|*[!0-9]*) n_items=0 ;;
esac

if [ "$n_items" -eq 0 ]; then
  log "  0 filas — se conserva lo publicado"
  exit 1
fi

# ── 4) GUARDA CONTRA VOLCADOS INCOMPLETOS ───────────────────────────────────
# Publicar media tabla le borra a todos los usuarios la mitad del contenido
# hasta la proxima corrida. Ante la duda, lo viejo y completo.
publicado=0
[ -f "$SALIDA/${NOMBRE}.json" ] && publicado=$(python3 "$CONTADOR" "$SALIDA/${NOMBRE}.json" 2>/dev/null || echo 0)

if [ "$publicado" -lt 0 ]; then
  log "  el volcado publicado esta ilegible — se reemplaza sin comparar"
elif [ "$publicado" -gt 0 ]; then
  minimo=$(( publicado * MIN_PORCENTAJE / 100 ))
  if [ "$n_items" -lt "$minimo" ]; then
    log "  SOSPECHOSO ${n_items} filas vs ${publicado} publicadas (<${MIN_PORCENTAJE}%) — se conserva lo publicado"
    exit 1
  fi
fi

# ── 5) PUBLICAR SOLO SI CAMBIO (ETag) ───────────────────────────────────────
hash_nuevo=$(sha256sum "$f_out" | cut -d' ' -f1)
hash_viejo=""
[ -f "$SALIDA/${NOMBRE}.json" ] && hash_viejo=$(sha256sum "$SALIDA/${NOMBRE}.json" | cut -d' ' -f1)

if [ "$hash_nuevo" = "$hash_viejo" ]; then
  echo "$huella" > "$ESTADO"
  [ "$forzar" -eq 1 ] && echo "$hoy" > "$FORZADO"
  log "  sin cambios ($n_items filas) — no se toca, ETag intacto"
  exit 0
fi

if ! gzip -9 -c "$f_out" > "$TMP/${NOMBRE}.json.gz"; then
  log "  ERROR al comprimir — se conserva lo publicado"
  exit 1
fi

# mv dentro del mismo sistema de archivos es atomico: nginx nunca sirve un
# archivo a medio escribir. El .gz va PRIMERO para que gzip_static jamas quede
# apuntando a una version mas vieja que el .json.
mv -f "$TMP/${NOMBRE}.json.gz" "$SALIDA/${NOMBRE}.json.gz" || exit 1
mv -f "$f_out"                 "$SALIDA/${NOMBRE}.json"    || exit 1
chmod 644 "$SALIDA/${NOMBRE}.json" "$SALIDA/${NOMBRE}.json.gz"

# El estado se guarda AL FINAL, solo si todo salio bien. Si algo fallo antes,
# la huella vieja sobrevive y la proxima corrida vuelve a intentarlo.
echo "$huella" > "$ESTADO"
[ "$forzar" -eq 1 ] && echo "$hoy" > "$FORZADO"

gz=$(stat -c %s "$SALIDA/${NOMBRE}.json.gz" 2>/dev/null || echo 0)
plano=$(stat -c %s "$SALIDA/${NOMBRE}.json" 2>/dev/null || echo 0)
log "=== fin: ACTUALIZADO $n_items filas | $(( plano / 1024 ))KB -> gz $(( gz / 1024 ))KB ==="
exit 0
