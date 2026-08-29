# Alias de títulos automáticos desde TMDB

Rellena solo la columna `title_aliases` de `custom_content` con los otros
nombres de cada película o serie, para que un título de la BD en español
enganche también con la copia en inglés de Xtream (y al revés).

---

## Por qué

El enlace entre la BD y Xtream se decide comparando **texto**. Y una traducción
no se parece a su original: *Captain America: The First Avenger* y *Capitán
América: El primer vengador* no comparten **ni una sola palabra**. Ningún
algoritmo de similitud puede unirlos, porque la información no está en el texto.

Hasta ahora eso se parcheaba con una tabla de equivalencias escrita a mano
dentro de la app (`vengadores→avengers`, `la casa de papel→money heist`…). Había
que añadir cada película a mano, y lo que no estaba en la lista no enganchaba.

Este script sustituye esa tabla por datos reales de TMDB.

**Se calcula en el VPS, no en la app**, por lo mismo que `bd.sh`: una vez y para
todos, en vez de miles de consultas diarias desde los teléfonos.

---

## 1. La columna

Si no existe todavía, en el editor SQL de Supabase:

```sql
ALTER TABLE custom_content ADD COLUMN IF NOT EXISTS title_aliases text[];
```

## 2. La clave de Supabase — **atención, esta sí escribe**

A diferencia de `bd.sh`, que solo lee y usa la clave `anon`, este script
**modifica filas**. Con la clave `anon` fallará en silencio si hay RLS activo.

Tenés dos opciones:

**a) Clave `service_role`** (Project Settings → API Keys). Es la más simple.
Se salta el RLS, así que **no puede salir del VPS bajo ningún concepto**: no la
pongas en la app, ni en el repo, ni en un archivo servido por nginx.

**b) Una política RLS que permita solo esta columna.** Más trabajo, pero acota
el daño si la clave se filtra:

```sql
CREATE POLICY alias_update ON custom_content
  FOR UPDATE TO anon USING (true) WITH CHECK (true);
```

> Recomendación: **(a)**, con el archivo en `chmod 600`. El script corre en el
> VPS y la clave nunca se transmite a ningún cliente.

## 3. El archivo de configuración

En el VPS (`ssh root@217.216.80.212`):

```bash
cat > /etc/alias-tmdb.conf <<'FIN'
SUPABASE_URL=https://inukqboqdvwtmmthjwrl.supabase.co
SUPABASE_KEY=TU_CLAVE_CON_PERMISO_DE_ESCRITURA
TMDB_KEY=4d1a1f42684a12a2fed02f05b35b4bb8
MAX=400
PAUSA=0.25
FIN
chmod 600 /etc/alias-tmdb.conf
```

| Ajuste | Para qué |
|---|---|
| `MAX` | Filas por corrida. `0` = sin límite (útil en la primera pasada). |
| `PAUSA` | Segundos entre títulos. Son 3 peticiones a TMDB por título. |
| `REINTENTAR_VACIOS` | `1` para reprocesar las que quedaron sin resultado. |

## 4. Instalar y ejecutar

```bash
install -m 755 alias-tmdb.sh /usr/local/bin/alias-tmdb.sh
```

La **primera pasada** conviene hacerla a mano y sin límite, para dejar el
catálogo entero resuelto de una vez:

```bash
MAX=0 /usr/local/bin/alias-tmdb.sh; tail -40 /var/log/alias-tmdb.log
```

Con unos pocos miles de películas y series son 3 peticiones cada una a ~4
títulos por segundo: cuestión de minutos. Los episodios se saltan (no se
enlazan por título con Xtream, así que gastar peticiones en ellos no aporta).

## 5. Dejarlo en cron

Una vez al día basta: solo mira las filas nuevas.

```bash
crontab -e
```

```cron
30 3 * * * /usr/local/bin/alias-tmdb.sh
```

A las 3:30, antes del volcado forzado de `bd.sh` (que por defecto va a las 4:00),
para que los alias nuevos entren en el `bd.json` de esa misma madrugada.

## 6. Comprobar

```bash
grep -c '^.*OK "' /var/log/alias-tmdb.log
curl -s https://TU_DOMINIO/catalogo/bd.json | grep -o 'title_aliases' | wc -l
```

---

## Cómo decide, y por qué es conservador

**Un alias equivocado es peor que no tener alias**: haría que dos películas
distintas se fusionaran en la app. Por eso el script prefiere quedarse corto.

Para cada título prueba varias consultas, de la más fiel a la más simple (sin
paréntesis, sin subtítulo tras el primer `:`), y para cada una acepta un
resultado por dos vías, en este orden:

1. **Por año** (± 1). Es el desempate más fiable que existe entre remakes y
   secuelas, así que si cuadra se acepta sin mirar más.
2. **Por texto casi idéntico**, ignorando el año. Solo se llega aquí si ningún
   candidato cuadró por año, y existe porque en la BD hay años sencillamente
   equivocados — *Avengers: Endgame (2025)*, que es de 2019. Al exigir
   prácticamente el mismo título, el riesgo se queda en nada.

Y por encima de todo, una guarda que **no se salta nunca**: si los números no
coinciden, no hay match. Sin ella, *«Reliquias de la Muerte 1»* se emparejaba
con la *Parte 2*, y *Toy Story* con *Toy Story 2* — las comparaciones de texto
trabajan con palabras de 3+ letras y tiraban los dígitos justo cuando eran la
única diferencia.

Ante la duda, la fila se queda sin alias. Quedarse corto solo mantiene el
comportamiento actual; equivocarse rompe algo que hoy funciona.

### Lo que sigue sin resolverse

Erratas en el título de la BD. *«La casa **del** papel»* no la encuentra TMDB,
y el script no adivina. Se arregla corrigiendo el título, o poniendo el alias a
mano.

## Idempotencia

Solo se miran las filas con `title_aliases` a `NULL`:

- Se encontró algo fiable → se escribe la lista.
- No se encontró → se escribe una lista **vacía**, que marca "ya se intentó" y
  evita reintentarla cada noche.

Para volver a probar esas, `REINTENTAR_VACIOS=1 /usr/local/bin/alias-tmdb.sh`.

## Si algo va mal

| Síntoma | Causa probable |
|---|---|
| `no hay filas pendientes` y no hay alias en la BD | La columna no existe, o el `PATCH` lo bloquea el RLS (ver paso 2). |
| Todas salen "sin resultado fiable" | `TMDB_KEY` mala. Probá: `curl "https://api.themoviedb.org/3/movie/1726?api_key=TU_CLAVE"`. |
| Los alias están en Supabase pero la app no los ve | Falta regenerar el volcado: `/usr/local/bin/bd.sh`. La app lee del VPS, no de Supabase. |
| `otra corrida sigue en marcha` | La primera pasada aún corre. Normal; el cron se salta solo. |

## Revertir

No hace falta tocar la app: con la columna vacía, el match se comporta
exactamente como antes.

```sql
UPDATE custom_content SET title_aliases = NULL;
```

Y quitar la línea del `crontab`.
