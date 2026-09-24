# Migrar a un proyecto nuevo de Supabase

## Paso 1: Crear el proyecto nuevo

1. Crea una cuenta nueva en supabase.com (email diferente)
2. Crea un proyecto nuevo (misma region `us-west-1` para menor latencia)
3. Anota la **URL** y la **anon key** del proyecto nuevo (Settings > API)

## Paso 2: Crear el schema + datos pequeños

1. Ve al SQL Editor del proyecto NUEVO
2. Copia y pega TODO el contenido de `migracion-supabase.sql`
3. Ejecuta

Eso crea todas las tablas, indices, funciones, triggers, RLS y los datos
de `sys_config` y `m3u_load_balancer`.

## Paso 3: Importar custom_content (39.655 filas)

Es demasiado grande para un INSERT. Opciones:

### Opcion A: Desde el VPS (recomendada)

El VPS ya tiene `bd.json` con todo el catalogo. Desde el VPS:

```bash
# Convertir bd.json a CSV para importar
python3 -c "
import json, csv, sys
with open('/var/www/catalogo/bd.json') as f:
    items = json.load(f)['items']
with open('/tmp/custom_content.csv', 'w', newline='') as f:
    w = csv.DictWriter(f, fieldnames=[
        'id','title','title_aliases','video_url','thumbnail_url',
        'type','parent_id','category','season','episode','is_active','created_at'
    ])
    w.writeheader()
    for item in items:
        item.setdefault('is_active', True)
        item.setdefault('title_aliases', None)
        w.writerow({k: item.get(k) for k in w.fieldnames})
print(f'{len(items)} filas exportadas')
"
```

Luego sube el CSV al proyecto nuevo via Table Editor > Import CSV, o usa
la API REST del proyecto nuevo con un script.

### Opcion B: Copiar via API REST

```bash
# En el VPS, enviar bd.json al proyecto nuevo via REST
NUEVA_URL="https://XXXXXXXXXX.supabase.co"
NUEVA_KEY="eyJ..."

# Desactivar los triggers de thumbnail temporalmente (son BEFORE INSERT)
# para que no borren los thumbnails que ya estan limpios.
# Hacerlo desde el SQL Editor del proyecto nuevo:
#   ALTER TABLE custom_content DISABLE TRIGGER trg_limpiar_thumb_episodio;
#   ALTER TABLE custom_content DISABLE TRIGGER trg_limpiar_thumbs_de_la_serie;

python3 -c "
import json, requests
with open('/var/www/catalogo/bd.json') as f:
    items = json.load(f)['items']

URL = '$NUEVA_URL/rest/v1/custom_content'
HEADERS = {
    'apikey': '$NUEVA_KEY',
    'Authorization': 'Bearer $NUEVA_KEY',
    'Content-Type': 'application/json',
    'Prefer': 'resolution=merge-duplicates'
}

# Insertar en lotes de 500
for i in range(0, len(items), 500):
    lote = items[i:i+500]
    for item in lote:
        item.setdefault('is_active', True)
    r = requests.post(URL, json=lote, headers=HEADERS)
    print(f'Lote {i}-{i+len(lote)}: {r.status_code}')
    if r.status_code >= 400:
        print(r.text[:200])
        break
print(f'Total: {len(items)} filas')
"

# Reactivar triggers:
#   ALTER TABLE custom_content ENABLE TRIGGER trg_limpiar_thumb_episodio;
#   ALTER TABLE custom_content ENABLE TRIGGER trg_limpiar_thumbs_de_la_serie;
```

## Paso 4: Datos manuales

Estas tablas las tienes que meter tu:

- **admin_users**: 1 fila. Inserta tu usuario admin manualmente desde el SQL
  Editor (tiene password_hash, no lo puedo exportar aqui).
- **home_banners**: 28 filas. Exportalas desde el Table Editor del proyecto
  viejo (descargar CSV) e importalas en el nuevo.
- **tv_devices**: 108 filas. Son los televisores vinculados. Cuando migres,
  los TVs van a tener que revincular (el token cambia). Si quieres evitarlo,
  exporta e importa la tabla.

## Paso 5: Edge Function tv-pairing

El codigo de la Edge Function `tv-pairing` ya lo tienes en el proyecto
(lo usa la app para vincular televisores).

1. Instala Supabase CLI: `npm i -g supabase`
2. Linkea el proyecto nuevo: `supabase link --project-ref NUEVO_REF`
3. Crea la funcion:

```bash
mkdir -p supabase/functions/tv-pairing
# Copia el index.ts y deno.json de la funcion (estan en el proyecto viejo,
# o pideme que los guarde como archivos)
supabase functions deploy tv-pairing
```

4. Configura el secreto de RevenueCat:
```bash
supabase secrets set REVENUECAT_SECRET_KEY=sk_XXXXXXXX
```

## Paso 6: Actualizar la app

En tu `.env` (o en las constantes de `m3u_service.dart`), cambia:

```
SUPABASE_URL=https://NUEVO_REF.supabase.co
SUPABASE_ANON_KEY=eyJ...nueva...
```

## Paso 7: Actualizar el VPS

Edita `/etc/bd.conf` en el VPS con las credenciales nuevas:

```bash
SUPABASE_URL="https://NUEVO_REF.supabase.co"
SUPABASE_KEY="eyJ...nueva..."
```

Los scripts `bd.sh` y `config.sh` empezaran a leer del proyecto nuevo
en la siguiente corrida del cron.

## Paso 8: Publicar update de la app

Compila y publica la app con las credenciales nuevas. Los usuarios que
actualicen empezaran a usar el proyecto nuevo automaticamente.
