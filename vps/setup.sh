# ============================================================================
#  Proxy con caché para Xtream — instalación completa
#  Uso:  bash setup.sh USUARIO CLAVE
# ============================================================================
# Sin `set -e`: si se pega en una sesión interactiva, cerraría la sesión.

USUARIO="$1"
CLAVE="$2"

echo "==> 1/6 Instalando nginx..."
apt-get update -qq
apt-get install -y -qq nginx curl

echo "==> 2/6 Preparando caché..."
mkdir -p /var/cache/vod /var/cache/vodapi /var/cache/img
chown -R www-data:www-data /var/cache/vod /var/cache/vodapi /var/cache/img

if [[ "$*" == *"--limpiar"* ]]; then
  echo "    [!] Flag --limpiar detectado: vaciando carpetas de caché..."
  rm -rf /var/cache/vod/* /var/cache/vodapi/* /var/cache/img/*
else
  echo "    [+] Preservando caché existente (usá --limpiar para vaciarla)."
fi

# Ubuntu trae un sitio de ejemplo que ya ocupa el puerto 80 como
# default_server; sin quitarlo, nginx -t falla por "duplicate default server".
rm -f /etc/nginx/sites-enabled/default

echo "==> 3/6 Escribiendo configuración..."
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
#
# Va separada A PROPOSITO: el modulo `slice` trabaja con subpeticiones
# internas, y en ese contexto la cabecera Location del 302 NO se propaga a la
# named location -> $upstream_http_location llega vacio y nginx responde 500
# ("invalid URL prefix"). Aqui, sin slice de por medio, el patron funciona.
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
    # Los servidores IPTV suelen mandar cabeceras anti-cache que impedirian
    # guardar nada; se ignoran a proposito.
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

    # Video. usuario/clave se capturan aparte para NO meterlos en la clave de
    # cache: asi el cache sobrevive a un cambio de contrasena.
    location ~ ^/(?<tipo>movie|series)/(?<usuario>[^/]+)/(?<clave>[^/]+)/(?<item>.+)$ {
        slice 1m;
        proxy_set_header Range $slice_range;

        # Un slice son 1 MB, pero los proxy_buffers por defecto son 8x4k = 32 KB
        # y arriba hay un `proxy_max_temp_file_size 0` que prohibe el fichero
        # temporal. Resultado: nginx no puede absorber el slice y queda atado a
        # la velocidad del CLIENTE. Con un movil a 1-2 Mbps el fetch al origen
        # se arrastra hasta que se corta -> "Connection closed while receiving
        # data" desde el primer chunk.
        #
        # Con 1,25 MB de buffers el slice entra entero en memoria, nginx lo
        # termina de bajar a la velocidad del ORIGEN, lo cachea, y despues se
        # lo va dando al cliente a su ritmo. Cuesta ~1,25 MB por conexion
        # activa, que a cambio de esto sale barato.
        proxy_buffer_size 64k;
        proxy_buffers     20 64k;

        # OJO: aqui NO va `proxy_ignore_client_abort on` (si va en /images/).
        #
        # En imagenes la respuesta pesa ~150 KB y esta acotada, asi que dejar
        # que termine tras un abort es barato. Aqui la respuesta es la PELICULA
        # ENTERA: si nginx ignora el abort, sigue pidiendo slices al origen
        # hasta terminarla. Un usuario que abre y cierra cinco titulos dejaria
        # cinco peliculas completas descargandose solas de fondo, quemando
        # ancho de banda del proveedor y llenando el disco.
        #
        # No hace falta: los slices YA completados se cachean igual sobre la
        # marcha. Un corte solo pierde el slice en vuelo, y el reintento de la
        # app vuelve a pedir ese 1 MB. Es barato.

        proxy_cache              vod;
        proxy_cache_key          "$tipo/$item$slice_range";
        # Solo 206: un 200 aqui significa error o que ignoraron el Range.
        proxy_cache_valid        206 30d;
        proxy_cache_lock         on;
        proxy_cache_lock_timeout 30s;

        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8081;

        add_header X-Cache $upstream_cache_status always;
    }

    # Caratulas por ruta directa /images/...
    #
    # proxy_ignore_client_abort ES CLAVE: la app corre una carrera entre el VPS
    # y el origen, y en cuanto gana uno ABORTA al otro. Sin esta directiva, cada
    # abort cancelaria tambien la descarga upstream y la caratula NUNCA quedaria
    # cacheada -> siempre MISS, siempre lenta. Con ella, nginx termina de bajarla
    # y la guarda igual: cada miss se precarga solo y la proxima vez sale del
    # disco.
    location /images/ {
        proxy_ignore_client_abort on;

        proxy_cache               img;
        proxy_cache_key           "$uri";
        proxy_cache_valid         200 60d;
        proxy_cache_valid         404 403 1h;
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

        # Ver la nota en /images/ — sin esto, la carrera de la app dejaria la
        # cache vacia para siempre.
        proxy_ignore_client_abort on;

        proxy_cache               img;
        proxy_cache_key           "$arg_url";
        proxy_cache_valid         200 60d;
        proxy_cache_valid         404 403 1h;
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

echo "==> 4/6 Validando..."
if ! nginx -t 2>&1; then
  echo ""
  echo "!!! Configuracion invalida. nginx queda como estaba."
  exit 1
fi

echo "==> 5/6 Recargando nginx y configurando guardián..."
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

cat << 'GUARD' > /etc/cron.hourly/vod-guard
#!/bin/bash
U=$(df --output=pcent / | tail -1 | tr -dc "0-9")
if [ "$U" -ge 90 ]; then
  find /var/cache/vod -type f -printf "%A@ %p\n" 2>/dev/null | sort -n | head -n 3000 | cut -d" " -f2- | xargs -r rm -f
  logger -t vod-guard "Disco al ${U}%: purgada cache antigua"
fi
GUARD
chmod +x /etc/cron.hourly/vod-guard


if [ -z "$USUARIO" ] || [ -z "$CLAVE" ]; then
  echo ""
  echo "==> 6/6 Sin credenciales, salteo la prueba."
  echo "    Volve a correr:  bash setup.sh TU_USUARIO TU_CLAVE"
  exit 0
fi

echo "==> 6/6 Probando la cache (2 peticiones al mismo trozo)..."
echo ""
ID=759711
for i in 1 2; do
  echo "--- Intento $i ---"
  curl -s -o /dev/null -D - -H "Range: bytes=0-1048575" \
    "http://127.0.0.1/movie/$USUARIO/$CLAVE/$ID.mkv" \
    | grep -iE "^HTTP/|x-cache"
done

echo ""
echo "======================================================"
echo " Esperado:  intento 1 -> 206 + X-Cache: MISS"
echo "            intento 2 -> 206 + X-Cache: HIT"
echo ""
echo " Si ves HIT, la cache funciona: ese contenido ya no"
echo " vuelve a consumir conexiones del proveedor."
echo "======================================================"
echo ""
echo "Ultimos errores de nginx (vacio = todo bien):"
tail -5 /var/log/nginx/error.log | grep -v "usr/share/nginx/html" || true
