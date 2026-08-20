# ============================================================================
#  Cache de caratulas en el VPS — pegar en el servidor
# ============================================================================
#
#  DIMENSIONADO (importante: que no se llene el disco)
#  ---------------------------------------------------
#  Disco total: 96 GB. Reparto:
#     video     60 GB   (se BAJA de 70 para hacerle lugar a las imagenes)
#     imagenes  10 GB   (el catalogo entero son ~3,8 GB -> sobra el triple)
#     catalogo   2 GB
#     sistema    ~4 GB
#     ----------------
#     libre     ~20 GB de margen
#
#  Las caratulas pesan ~150 KB y NUNCA cambian, asi que se cachean 60 dias.
#  Con 25.624 titulos el catalogo completo ocupa ~3,8 GB: entra de sobra y a
#  partir de la segunda vista se sirve del disco sin tocar al proveedor.
# ============================================================================

set -e

echo "==> 1/4 Creando cache de imagenes..."
mkdir -p /var/cache/img
chown -R www-data:www-data /var/cache/img

echo "==> 2/4 Configurando cache de video (60GB) e imagenes (10GB)..."
cat > /etc/nginx/conf.d/vod.conf <<'NGINXCONF'
proxy_cache_path /var/cache/vod    levels=1:2 keys_zone=vod:200m
                 max_size=60g inactive=30d use_temp_path=off;
proxy_cache_path /var/cache/vodapi levels=1:2 keys_zone=vodapi:20m
                 max_size=2g  inactive=1h  use_temp_path=off;
proxy_cache_path /var/cache/img    levels=1:2 keys_zone=img:50m
                 max_size=10g inactive=60d use_temp_path=off;

upstream proveedor {
    server red4tv.lat:80;
    keepalive 16;
}

upstream origen_imagenes {
    server ultratvsv.site:80;
    keepalive 32;
}

map $arg_url $uri_de_imagen {
    default                          "";
    "~*^https?://[^/]+(?<ruta>/.*)$" $ruta;
}

# ---------------------------------------------------------------------------
# CAPA 2 (interna, 127.0.0.1:8081) — resuelve el redirect 302 del proveedor.
# ---------------------------------------------------------------------------
server {
    listen 127.0.0.1:8081;

    location / {
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host red4tv.lat;
        proxy_set_header Range $http_range;

        proxy_pass http://proveedor;

        proxy_intercept_errors on;
        error_page 301 302 307 = @redir;
    }

    location @redir {
        resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
        set $saved_location $upstream_http_location;
        proxy_http_version 1.1;
        proxy_set_header Range $http_range;
        proxy_pass $saved_location;
    }
}

# ---------------------------------------------------------------------------
# CAPA 1 (publica, puerto 80) — Video, API y Caratulas
# ---------------------------------------------------------------------------
server {
    listen 80 default_server;
    server_name _;

    proxy_max_temp_file_size 0;
    proxy_ignore_headers Cache-Control Expires Set-Cookie X-Accel-Expires;

    # Catalogo: cada arranque de la app pide 25.000+ titulos al proveedor.
    location = /player_api.php {
        proxy_cache       vodapi;
        proxy_cache_key   "$request_uri";
        proxy_cache_valid 200 10m;
        proxy_cache_lock  on;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host red4tv.lat;
        proxy_pass http://proveedor;

        add_header X-Cache $upstream_cache_status always;
    }

    # Video.
    location ~ ^/(?<tipo>movie|series)/(?<usuario>[^/]+)/(?<clave>[^/]+)/(?<item>.+)$ {
        slice 1m;
        proxy_set_header Range $slice_range;

        proxy_cache              vod;
        proxy_cache_key          "$tipo/$item$slice_range";
        proxy_cache_valid        206 30d;
        proxy_cache_lock         on;
        proxy_cache_lock_timeout 30s;

        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8081;

        add_header X-Cache $upstream_cache_status always;
    }

    # Caratulas por ruta directa /images/...
    location /images/ {
        proxy_cache               img;
        proxy_cache_key           "$uri";
        proxy_cache_valid         200 60d;
        proxy_cache_valid         404 403 1m;
        proxy_cache_valid         any 1m;
        proxy_cache_lock          on;
        proxy_cache_lock_timeout  10s;
        proxy_cache_use_stale     error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_revalidate    on;
        proxy_ignore_headers      Cache-Control Expires Set-Cookie X-Accel-Expires;
        proxy_connect_timeout     4s;
        proxy_read_timeout        8s;
        proxy_send_timeout        4s;
        proxy_http_version        1.1;
        proxy_set_header          Connection "";
        proxy_set_header          Host ultratvsv.site;
        proxy_set_header          User-Agent "Mozilla/5.0 (Linux; Android 13)";
        proxy_pass                http://origen_imagenes;
        add_header                Cache-Control "public, max-age=2592000" always;
        add_header                X-Cache $upstream_cache_status always;
    }

    # Caratulas por parametro /img?url=<url>
    location = /img {
        if ($arg_url = "") { return 400; }

        proxy_cache               img;
        proxy_cache_key           "$arg_url";
        proxy_cache_valid         200 60d;
        proxy_cache_valid         404 403 1m;
        proxy_cache_valid         any 1m;
        proxy_cache_lock          on;
        proxy_cache_lock_timeout  10s;
        proxy_cache_use_stale     error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_revalidate    on;
        proxy_ignore_headers      Cache-Control Expires Set-Cookie X-Accel-Expires;
        proxy_connect_timeout     4s;
        proxy_read_timeout        8s;
        proxy_send_timeout        4s;
        proxy_http_version        1.1;
        proxy_set_header          Connection "";
        proxy_set_header          Host ultratvsv.site;
        proxy_set_header          User-Agent "Mozilla/5.0 (Linux; Android 13)";
        proxy_pass                http://origen_imagenes$uri_de_imagen;
        add_header                Cache-Control "public, max-age=2592000" always;
        add_header                X-Cache $upstream_cache_status always;
    }
}
NGINXCONF

echo "==> 4/4 Validando y recargando..."
if ! nginx -t; then
  echo ""
  echo "!!! Configuracion invalida. Revisar el error de arriba."
  echo "!!! nginx sigue con la configuracion anterior."
  exit 1
fi
systemctl reload nginx

echo ""
echo "======================================================"
echo " LISTO. Probando la cache de imagenes..."
echo "======================================================"
IMG="http://ultratvsv.site:80/images/1CX9HZ1TpsR6jq_dGSnHkF7DaaYG-JnaH_5zbvTz1M5mB5g6BUIWNSoocDNYisyLVipaAF4QJbwDnWQMvdXMiUG5xG3PO-z_HAgGFSW3xp0.jpg"
for i in 1 2; do
  echo "--- Intento $i ---"
  curl -s -m 20 -o /dev/null -D - "http://127.0.0.1/img?url=$IMG" | grep -iE "^HTTP/|x-cache|content-type"
done
echo ""
echo " Esperado: intento 1 -> 200 OK + MISS, intento 2 -> 200 OK + HIT"
echo ""
df -h / | tail -1
