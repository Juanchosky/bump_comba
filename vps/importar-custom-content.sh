#!/bin/bash
# ============================================================================
#  Importar custom_content desde bd.json al proyecto NUEVO de Supabase
#  Ejecutar en el VPS donde ya existe /var/www/catalogo/bd.json
# ============================================================================

set -euo pipefail

NUEVA_URL="https://ezcnqtpmfqfnsqupimrq.supabase.co"
NUEVA_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV6Y25xdHBtZnFmbnNxdXBpbXJxIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc5MDI4NzkxNywiZXhwIjoyMTA1ODYzOTE3fQ.W7OKMZEF80GsMENgv32co148nH09g4O8t_C2yelEuPQ"

BD_JSON="/var/www/catalogo/bd.json"

if [ ! -f "$BD_JSON" ]; then
  echo "ERROR: no existe $BD_JSON"
  exit 1
fi

TOTAL=$(python3 -c "import json; print(len(json.load(open('$BD_JSON'))['items']))")
echo "Total filas en bd.json: $TOTAL"

# Insertar series y movies primero (no tienen parent_id con dependencia)
# Luego episodes (que sí tienen parent_id)
python3 - "$NUEVA_URL" "$NUEVA_KEY" "$BD_JSON" <<'PYEOF'
import json, sys, requests, time

url_base = sys.argv[1]
key = sys.argv[2]
bd_path = sys.argv[3]

with open(bd_path, encoding='utf-8') as f:
    items = json.load(f)['items']

ENDPOINT = f"{url_base}/rest/v1/custom_content"
HEADERS = {
    'apikey': key,
    'Authorization': f'Bearer {key}',
    'Content-Type': 'application/json',
    'Prefer': 'resolution=merge-duplicates'
}

# Separar: primero series/movies, luego episodes
padres = [i for i in items if i.get('type') != 'episode']
hijos  = [i for i in items if i.get('type') == 'episode']

print(f"Padres (series+movies): {len(padres)}")
print(f"Hijos  (episodes):      {len(hijos)}")

from datetime import datetime, timezone
now_iso = datetime.now(timezone.utc).isoformat()

def normalize(item):
    s = item.get('season')
    try:
        season = int(s) if s is not None and str(s).strip() != '' else None
    except (ValueError, TypeError):
        season = None

    ep = item.get('episode')
    try:
        episode = int(ep) if ep is not None and str(ep).strip() != '' else None
    except (ValueError, TypeError):
        episode = None

    aliases = item.get('title_aliases')
    if not isinstance(aliases, list):
        aliases = None

    return {
        'id': item.get('id'),
        'title': str(item.get('title') or 'Sin título'),
        'type': item.get('type') or 'movie',
        'category': item.get('category') or 'Recomendados',
        'video_url': item.get('video_url') or None,
        'thumbnail_url': item.get('thumbnail_url') or None,
        'parent_id': item.get('parent_id') or None,
        'season': season,
        'episode': episode,
        'is_active': item.get('is_active', True) if item.get('is_active') is not None else True,
        'title_aliases': aliases,
        'created_at': item.get('created_at') or now_iso,
        'updated_at': item.get('updated_at') or item.get('created_at') or now_iso
    }

BATCH = 500
errores = 0

def insertar(lista, label):
    global errores
    for i in range(0, len(lista), BATCH):
        raw_lote = lista[i:i+BATCH]
        lote = [normalize(item) for item in raw_lote]
        fin = i + len(lote)
        try:
            r = requests.post(ENDPOINT, json=lote, headers=HEADERS, timeout=45)
            status = r.status_code
            if status < 400:
                print(f"  {label} {i+1}-{fin}/{len(lista)}: OK ({status})")
            else:
                print(f"  {label} {i+1}-{fin}/{len(lista)}: ERROR {status}")
                print(f"    {r.text[:300]}")
                errores += 1
                if errores > 5:
                    print("Demasiados errores, abortando.")
                    sys.exit(1)
        except Exception as e:
            print(f"  {label} {i+1}-{fin}/{len(lista)}: EXCEPCION {e}")
            errores += 1
            if errores > 5:
                print("Demasiadas excepciones, abortando.")
                sys.exit(1)
        time.sleep(0.1)

print("\n== Insertando padres ==")
insertar(padres, "padres")

print("\n== Insertando episodes ==")
insertar(hijos, "episodes")

print(f"\nListo. Errores: {errores}")
PYEOF
