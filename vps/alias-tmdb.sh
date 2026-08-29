#!/bin/bash
# ============================================================================
#  Alias de titulos desde TMDB (custom_content) — bump_comba
#  Instalar en: /usr/local/bin/alias-tmdb.sh   (cron 1 vez al dia)
# ============================================================================
#
#  QUE HACE
#  --------
#  Rellena la columna `title_aliases` de `custom_content` con los otros nombres
#  con los que se conoce cada pelicula o serie: el titulo original, el traducido
#  al espanol y los alternativos que publica TMDB.
#
#  POR QUE
#  -------
#  El enlace entre la BD y Xtream se decide comparando TEXTO. Y una traduccion
#  no se parece a su original: "Captain America: The First Avenger" y "Capitan
#  America: El primer vengador" no comparten ni una sola palabra. Ningun
#  algoritmo de similitud puede unirlos —ni Levenshtein, ni Jaccard— porque la
#  informacion no esta en el texto.
#
#  Antes esto se parcheaba con una tabla de equivalencias escrita a mano dentro
#  de la app (vengadores->avengers, la casa de papel->money heist...). Habia que
#  anadir cada pelicula una por una, y lo que no estaba en la lista, no
#  enganchaba. Este script sustituye esa tabla por datos reales.
#
#  POR QUE EN EL VPS Y NO EN LA APP
#  --------------------------------
#  Porque se calcula UNA vez y sirve para todos. Si cada telefono resolviera sus
#  propios alias serian miles de consultas diarias a TMDB y otro tanto de
#  escrituras en Supabase, que es justo la cuota que bd.sh vino a salvar.
#
#  EL RIESGO A EVITAR NO ES QUEDARSE CORTO, ES ACERTAR MAL
#  -------------------------------------------------------
#  Un alias equivocado es PEOR que no tener alias: haria que dos peliculas
#  distintas se fusionaran en la app. Por eso:
#
#    - Si el titulo trae ano, el resultado de TMDB tiene que coincidir con el
#      (+/- 1). Si no coincide, se prueba el siguiente resultado.
#    - Sin ano no se acepta cualquier cosa: el titulo tiene que parecerse de
#      verdad al que devuelve TMDB (ver `_bastante_parecido`).
#    - Ante la duda, se deja sin alias. Quedarse corto solo mantiene el estado
#      actual; equivocarse rompe algo que hoy funciona.
#
#  IDEMPOTENCIA
#  ------------
#  Solo se miran las filas con `title_aliases` a NULL. Cuando una se resuelve se
#  escribe su lista; cuando no se encuentra nada fiable se escribe una lista
#  VACIA, que marca "ya se intento" y evita reintentarla cada dia. Para volver a
#  probar esas, `REINTENTAR_VACIOS=1`.
#
#  CONFIGURACION: /etc/alias-tmdb.conf (ver INSTALAR-ALIAS-TMDB.md)
# ============================================================================

set -u

CONF=/etc/alias-tmdb.conf
[ -f "$CONF" ] || { echo "Falta $CONF"; exit 1; }

# El ENTORNO manda sobre el fichero de configuracion.
#
# `. "$CONF"` son asignaciones planas (`MAX=400`), asi que pisaban cualquier
# valor puesto delante en la linea de ordenes. El resultado es que el
# `MAX=0 alias-tmdb.sh` que documenta la primera pasada se ignoraba EN SILENCIO
# y la corrida se cortaba en 400 filas — con la agravante de que el resumen
# final no distingue "termine el catalogo" de "llegue al tope".
#
# Se guarda lo que venga del entorno antes de leer el fichero y se vuelve a
# poner despues.
_ENV_MAX=${MAX-}
_ENV_PAUSA=${PAUSA-}
_ENV_REINTENTAR=${REINTENTAR_VACIOS-}
_ENV_TIMEOUT=${TIMEOUT-}

# shellcheck disable=SC1090
. "$CONF"

[ -n "$_ENV_MAX" ] && MAX=$_ENV_MAX
[ -n "$_ENV_PAUSA" ] && PAUSA=$_ENV_PAUSA
[ -n "$_ENV_REINTENTAR" ] && REINTENTAR_VACIOS=$_ENV_REINTENTAR
[ -n "$_ENV_TIMEOUT" ] && TIMEOUT=$_ENV_TIMEOUT

: "${SUPABASE_URL:?falta SUPABASE_URL en $CONF}"
: "${SUPABASE_KEY:?falta SUPABASE_KEY en $CONF}"
: "${TMDB_KEY:?falta TMDB_KEY en $CONF}"
# Cuantas filas como maximo por corrida. 0 = sin limite (util en la primera
# pasada; despues quedan pocas y el limite deja de importar).
: "${MAX:=400}"
# Pausa entre titulos, en segundos. Son 3 peticiones a TMDB por titulo; con
# 0.25 salen ~4 titulos/s, muy por debajo de cualquier limite de TMDB.
: "${PAUSA:=0.25}"
# Volver a intentar las filas que ya se marcaron como "sin resultado".
: "${REINTENTAR_VACIOS:=0}"
: "${TIMEOUT:=20}"

LOG=/var/log/alias-tmdb.log
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Una sola corrida a la vez: si la anterior sigue viva (primera pasada larga),
# esta se va sin hacer nada en vez de duplicar peticiones a TMDB.
LOCK=/var/lock/alias-tmdb.lock
exec 9>"$LOCK" || { log "ERROR: no se pudo abrir $LOCK"; exit 1; }
if ! flock -n 9; then
  log "otra corrida sigue en marcha — se sale"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { log "ERROR: falta python3"; exit 1; }

log "=== inicio (MAX=$MAX, REINTENTAR_VACIOS=$REINTENTAR_VACIOS) ==="

export SUPABASE_URL SUPABASE_KEY TMDB_KEY MAX PAUSA REINTENTAR_VACIOS TIMEOUT

python3 - <<'PY' 2>&1 | while IFS= read -r linea; do log "$linea"; done
# -*- coding: utf-8 -*-
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

SUPABASE_URL = os.environ['SUPABASE_URL'].rstrip('/')
SUPABASE_KEY = os.environ['SUPABASE_KEY']
TMDB_KEY = os.environ['TMDB_KEY']
MAX = int(os.environ.get('MAX', '400'))
PAUSA = float(os.environ.get('PAUSA', '0.25'))
REINTENTAR = os.environ.get('REINTENTAR_VACIOS', '0') == '1'
TIMEOUT = int(os.environ.get('TIMEOUT', '20'))

REST = SUPABASE_URL + '/rest/v1/custom_content'
TMDB = 'https://api.themoviedb.org/3'

# Paises cuyos titulos alternativos interesan. El publico es hispanohablante y
# el proveedor mezcla copias en ingles, asi que con estos cinco se cubre casi
# todo sin llenar la lista de ruido (hay titulos en 40 idiomas).
PAISES = ('ES', 'MX', 'AR', 'US', 'GB')

# Cuantos alias se guardan como maximo. Mas de esto no aporta: son variantes
# cada vez mas raras y solo aumentan el riesgo de una coincidencia falsa.
TOPE_ALIAS = 8


def pedir(url, metodo='GET', cuerpo=None, cabeceras=None):
    datos = None
    if cuerpo is not None:
        datos = json.dumps(cuerpo).encode('utf-8')
    req = urllib.request.Request(url, data=datos, method=metodo)
    for k, v in (cabeceras or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        crudo = r.read()
        if not crudo:
            return None
        return json.loads(crudo.decode('utf-8'))


def supa(url, metodo='GET', cuerpo=None, extra=None):
    cab = {
        'apikey': SUPABASE_KEY,
        'Authorization': 'Bearer ' + SUPABASE_KEY,
        'Content-Type': 'application/json',
    }
    if extra:
        cab.update(extra)
    return pedir(url, metodo, cuerpo, cab)


def tmdb(ruta, **params):
    params['api_key'] = TMDB_KEY
    url = TMDB + ruta + '?' + urllib.parse.urlencode(params)
    return pedir(url)


# ── Limpieza del titulo antes de buscar ─────────────────────────────────────
#
# Los titulos de la BD llegan como "Capitan America: The First Avenger (2011)"
# o con etiquetas de calidad pegadas. TMDB busca peor con esa morralla dentro.
RE_ANIO = re.compile(r'[\(\[]?\b(19|20)\d{2}\b[\)\]]?')
RE_BASURA = re.compile(
    r'\b(1080p|720p|480p|2160p|4k|uhd|hd|sd|web-?dl|webrip|bluray|brrip|'
    r'hdrip|dvdrip|x264|x265|h264|h265|hevc|aac|ac3|dual|latino|castellano|'
    r'subtitulado|sub|vose|remux|ligero)\b',
    re.IGNORECASE,
)
RE_ESPACIOS = re.compile(r'\s+')


# Lo que va entre corchetes es SIEMPRE morralla del proveedor
# ("[Audio Latino]", "[1080p]"). Se borra entero, contenido incluido: antes se
# quitaban solo los corchetes y quedaba "Audio" ensuciando la busqueda.
RE_CORCHETES = re.compile(r'\[[^\]]*\]')
RE_PARENTESIS = re.compile(r'\([^\)]*\)')
# "Season 1", "Temporada 2", "T3" — sobra al buscar la serie en TMDB.
RE_TEMPORADA = re.compile(
    r'\b(season|temporada|temp|t)\s*\d+\b', re.IGNORECASE
)


def limpiar(titulo):
    t = RE_CORCHETES.sub(' ', titulo)
    t = RE_ANIO.sub(' ', t)
    t = RE_TEMPORADA.sub(' ', t)
    t = RE_BASURA.sub(' ', t)
    t = t.replace('[', ' ').replace(']', ' ').replace('_', ' ')
    return RE_ESPACIOS.sub(' ', t).strip(' -–—:.')


def variantes(titulo):
    """Consultas a probar, de la mas fiel a la mas simple.

    TMDB devuelve cero resultados cuando la consulta trae ruido de sobra
    ("The Vampire Diaries: Love Sucks. Diarios de vampiros"). Recortar por el
    primer `:` o `.` la salva, pero SOLO es seguro porque el candidato sigue
    teniendo que pasar la validacion por ano: sin ella, "Star Trek: En la
    oscuridad" recortado a "Star Trek" traeria la pelicula equivocada.
    """
    base = limpiar(titulo)
    fuera = []

    def anadir(v):
        v = RE_ESPACIOS.sub(' ', v or '').strip(' -–—:.')
        if len(v) >= 3 and v.lower() not in [x.lower() for x in fuera]:
            fuera.append(v)

    anadir(base)
    # Sin parentesis: "Toy Story (Juguetes)" -> "Toy Story".
    anadir(RE_PARENTESIS.sub(' ', base))
    # Solo lo anterior al primer separador de subtitulo.
    for sep in (':', ' - ', '.'):
        if sep in base:
            anadir(base.split(sep)[0])
    return fuera


def anio_de(titulo):
    m = RE_ANIO.search(titulo)
    if not m:
        return None
    solo = re.sub(r'[^\d]', '', m.group(0))
    return int(solo) if len(solo) == 4 else None


def plano(s):
    """Minusculas, sin acentos y sin puntuacion: para comparar, no para mostrar."""
    s = unicodedata.normalize('NFD', s or '')
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    s = re.sub(r'[^a-z0-9 ]', ' ', s.lower())
    return RE_ESPACIOS.sub(' ', s).strip()


def _palabras(s):
    return set(w for w in plano(s).split() if len(w) >= 3)


RE_NUM = re.compile(r'\b\d+\b')


def _numeros(s):
    """Los numeros del titulo, que son los que separan las secuelas.

    Sin esto, "Harry Potter y las Reliquias de la Muerte 1" se emparejaba con
    la "Parte 2", y "Toy Story" con "Toy Story 2": las comparaciones de texto
    trabajan con palabras de 3+ letras y tiraban los digitos justo cuando eran
    la unica diferencia. Un fallo asi es de los caros — fusiona dos peliculas
    distintas en la app.
    """
    return set(RE_NUM.findall(plano(s)))


def _bastante_parecido(a, b):
    """¿Son plausiblemente el mismo titulo?

    Se usa SOLO cuando no hay ano con el que confirmar. Es deliberadamente
    estricta: mas vale dejar una fila sin alias que fusionar dos peliculas.
    """
    pa, pb = plano(a), plano(b)
    if not pa or not pb:
        return False
    # Numeros distintos = secuelas distintas. Va lo primero, antes incluso
    # que la igualdad exacta, porque es un descarte, no un matiz.
    if _numeros(a) != _numeros(b):
        return False
    if pa == pb:
        return True
    wa, wb = _palabras(a), _palabras(b)
    if not wa or not wb:
        return False
    comunes = wa & wb
    # Que uno contenga al otro casi entero. Con dos palabras compartidas de
    # cinco no basta: "Capitan America Civil War" y "Capitan America El primer
    # vengador" comparten dos y son peliculas distintas.
    return len(comunes) >= min(len(wa), len(wb)) * 0.8


def _casi_igual(a, b):
    """Practicamente el mismo texto: como mucho una palabra distinta por lado.

    Es la unica via por la que se acepta un candidato IGNORANDO el ano, y por
    eso es mucho mas dura que `_bastante_parecido`. Existe porque en la BD hay
    anos sencillamente equivocados —"Avengers: Endgame (2025)", que es de
    2019— y ahi el titulo es la evidencia buena, no la fecha.
    """
    pa, pb = plano(a), plano(b)
    if not pa or not pb:
        return False
    # Numeros distintos = secuelas distintas. Va lo primero, antes incluso
    # que la igualdad exacta, porque es un descarte, no un matiz.
    if _numeros(a) != _numeros(b):
        return False
    if pa == pb:
        return True
    wa, wb = _palabras(a), _palabras(b)
    if not wa or not wb:
        return False
    comunes = wa & wb
    if not comunes:
        return False
    return len(wa - comunes) <= 1 and len(wb - comunes) <= 1


def elegir(resultados, titulo_limpio, anio, clave_titulo, clave_fecha):
    """El mejor resultado de TMDB que se pueda dar por bueno, o None.

    Dos pasadas, en este orden a proposito:

      1. Por ANO. Es el desempate mas fiable que existe entre remakes y
         secuelas, asi que si cuadra se acepta sin mirar mas.
      2. Por TEXTO casi identico, ignorando el ano. Solo se llega aqui si
         NINGUN candidato cuadro por ano, y sirve para las filas cuyo ano en la
         BD esta mal. Al exigir practicamente el mismo titulo, el riesgo de
         emparejar dos peliculas distintas se queda en nada.
    """
    candidatos = resultados[:5]

    if anio:
        for r in candidatos:
            fecha = (r.get(clave_fecha) or '')[:4]
            r_anio = int(fecha) if fecha.isdigit() else None
            if r_anio and abs(anio - r_anio) <= 1:
                return r

    for r in candidatos:
        for cand in (r.get(clave_titulo), r.get('original_' + clave_titulo)):
            if not cand:
                continue
            # Sin ano en la BD basta con parecerse; con ano (y por tanto tras
            # haber fallado la pasada 1) hay que ser casi identicos.
            if anio:
                if _casi_igual(titulo_limpio, cand):
                    return r
            elif _bastante_parecido(titulo_limpio, cand):
                return r
    return None


def alias_de(fila):
    """Lista de titulos alternativos para una fila, o [] si no hay nada fiable."""
    titulo = (fila.get('title') or '').strip()
    if not titulo:
        return []

    es_serie = (fila.get('type') or '').lower() == 'series'
    tipo = 'tv' if es_serie else 'movie'
    clave_titulo = 'name' if es_serie else 'title'
    clave_fecha = 'first_air_date' if es_serie else 'release_date'

    anio = anio_de(titulo)
    consultas = variantes(titulo)
    if not consultas:
        return []

    elegido = None
    limpio = consultas[0]
    for consulta in consultas:
        resultados = []

        # Acotando por ano primero: reduce muchisimo los falsos candidatos.
        if anio:
            p = {'query': consulta, 'language': 'es-ES'}
            p['first_air_date_year' if es_serie else 'primary_release_year'] = anio
            resultados = ((tmdb('/search/' + tipo, **p) or {}).get('results')) or []

        # Y sin acotar: TMDB a veces tiene la fecha de estreno de otro pais, y
        # ademas hay filas con el ano mal en la BD. El filtrado de verdad lo
        # hace `elegir`, no la busqueda.
        if not resultados or anio:
            sueltos = (
                (tmdb('/search/' + tipo, query=consulta, language='es-ES') or {})
                .get('results')
            ) or []
            vistos_id = {r.get('id') for r in resultados}
            for r in sueltos:
                if r.get('id') not in vistos_id:
                    resultados.append(r)

        elegido = elegir(resultados, consulta, anio, clave_titulo, clave_fecha)
        if elegido:
            limpio = consulta
            break

    if not elegido:
        return []

    ident = elegido.get('id')
    if not ident:
        return []

    nombres = []

    # 1) El traducido y el original, que son los dos que de verdad usan los
    #    proveedores.
    detalle = tmdb('/%s/%d' % (tipo, ident), language='es-ES') or {}
    for k in (clave_titulo, 'original_' + clave_titulo):
        v = detalle.get(k)
        if v:
            nombres.append(v.strip())

    # 2) Los alternativos de los paises que interesan.
    alt = tmdb('/%s/%d/alternative_titles' % (tipo, ident)) or {}
    for a in (alt.get('titles') or alt.get('results') or []):
        if a.get('iso_3166_1') in PAISES:
            v = (a.get('title') or '').strip()
            if v:
                nombres.append(v)

    # Dedup sin acentos ni mayusculas, conservando la primera grafia vista.
    # Tambien se quita el propio titulo de la fila: ya se compara por su cuenta.
    vistos = {plano(titulo)}
    fuera = []
    for n in nombres:
        p = plano(n)
        if not p or p in vistos:
            continue
        vistos.add(p)
        fuera.append(n)
        if len(fuera) >= TOPE_ALIAS:
            break
    return fuera


# ── 1) FILAS PENDIENTES ─────────────────────────────────────────────────────
#
# Solo peliculas y series: los episodios no se enlazan por titulo con Xtream,
# asi que gastar peticiones en ellos no aporta nada.
filtro = 'title_aliases=eq.%7B%7D' if REINTENTAR else 'title_aliases=is.null'
url = (
    REST
    + '?select=id,title,type&is_active=eq.true&type=in.(movie,series)&'
    + filtro
    + '&order=id'
)
if MAX > 0:
    url += '&limit=%d' % MAX

try:
    pendientes = supa(url) or []
except Exception as e:
    print('ERROR: no se pudo consultar Supabase: %s' % e)
    sys.exit(1)

if not pendientes:
    print('no hay filas pendientes')
    sys.exit(0)

print('%d filas pendientes' % len(pendientes))

# ── 2) RESOLVER Y GUARDAR ───────────────────────────────────────────────────
resueltas = 0
vacias = 0
fallos = 0

for fila in pendientes:
    ident = fila.get('id')
    if not ident:
        continue
    titulo = fila.get('title') or ''
    try:
        nombres = alias_de(fila)
    except Exception as e:
        # Un fallo de red en un titulo no debe tumbar la corrida: se deja la
        # fila en NULL y se reintenta manana sola.
        fallos += 1
        print('FALLO "%s": %s' % (titulo[:60], e))
        time.sleep(PAUSA)
        continue

    try:
        supa(
            REST + '?id=eq.' + urllib.parse.quote(str(ident)),
            metodo='PATCH',
            cuerpo={'title_aliases': nombres},
            extra={'Prefer': 'return=minimal'},
        )
    except Exception as e:
        fallos += 1
        print('FALLO al guardar "%s": %s' % (titulo[:60], e))
        time.sleep(PAUSA)
        continue

    if nombres:
        resueltas += 1
        print('OK "%s" -> %s' % (titulo[:60], ' | '.join(nombres[:3])))
    else:
        vacias += 1

    time.sleep(PAUSA)

print(
    'fin: %d con alias, %d sin resultado fiable, %d fallos'
    % (resueltas, vacias, fallos)
)
if MAX > 0 and len(pendientes) >= MAX:
    # Sin este aviso, "400 procesadas" se lee como "catalogo terminado" cuando
    # en realidad solo se llego al tope de la corrida.
    print(
        'AVISO: se alcanzo el tope de %d filas. QUEDAN MAS PENDIENTES: '
        'volve a ejecutar, o usa MAX=0 para hacerlo todo de una vez.' % MAX
    )
PY

log "=== fin ==="
