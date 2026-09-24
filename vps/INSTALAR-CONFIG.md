# Instalar config.sh — volcado de sys_config y load_balancer

Igual que `bd.sh` pero para las tablas de configuracion. Usa el mismo
`/etc/bd.conf` (las credenciales de Supabase ya estan ahi).

## 1. Copiar el script

```bash
sudo cp config.sh /usr/local/bin/config.sh
sudo chmod +x /usr/local/bin/config.sh
```

## 2. Ejecutar una vez a mano para verificar

```bash
sudo /usr/local/bin/config.sh
ls -la /var/www/catalogo/sys_config.json /var/www/catalogo/load_balancer.json
```

Deben aparecer los dos JSON. Si algo falla, revisar `/var/log/config-volcado.log`.

## 3. Agregar al cron

```bash
sudo crontab -e
```

Agregar la linea (cada 5 minutos, igual que bd.sh):

```
*/5 * * * * /usr/local/bin/config.sh
```

## Que se publica

| Archivo | Tabla | Peso tipico |
|---|---|---|
| `sys_config.json` | `sys_config` | ~1 KB |
| `load_balancer.json` | `m3u_load_balancer` | ~2 KB |

nginx ya sirve `/var/www/catalogo/` con `gzip_static on`, asi que los `.gz`
que genera el script se sirven directamente.

## Si Supabase esta caido

El script fallara al intentar bajar las tablas, pero los JSON ya publicados
se quedan intactos. La app los lee del VPS sin depender de Supabase.
