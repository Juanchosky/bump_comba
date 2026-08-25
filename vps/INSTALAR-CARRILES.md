# Carriles de ancho de banda: premium vs free

Separa el puerto del VPS en dos carriles para que la rafaga de precarga de un
usuario free no le robe el ancho a un premium que esta pagando.

---

## Por que

El techo de la app es el puerto del VPS (200 Mbit/s ≈ 25 MB/s), no el disco ni
el trafico. Cuando el puerto se satura, nginx no alcanza a leer del origen a
tiempo, la peticion se alarga y el proveedor la corta. En el log se ve como
`upstream prematurely closed connection`, y en el telefono como un corte de
reproduccion.

Hasta ahora todos competian por el mismo ancho. Con este cambio:

| | Primeros MB a tope | Sostenido despues |
|---|---|---|
| Free (`X-Bump-Tier: f`) | 8 MB | ~8 Mbps |
| Todo lo demas (premium, y quien no mande cabecera) | 24 MB | ~20 Mbps |

**El default es el carril bueno, a proposito.** Solo se estrangula a quien se
declara free. Si fuera al reves, desde que aplicas esta config hasta que la
version nueva de la app llega a las tiendas TODOS los usuarios quedarian
estrangulados a 8 Mbps —premium incluidos— porque ninguna app en la calle manda
todavia `X-Bump-Tier`. Asi el cambio es inocuo hasta que la app se identifique.

**`limit_rate` es por CONEXION, no por cliente.** TurboProxy abre hasta 4
piernas en paralelo para un mismo stream, asi que un free ve ~4 x 8 = 32 Mbps
en total. Los valores estan elegidos con eso en cuenta: lo que se corta es la
rafaga de cada pierna.

Un 1080p de este proveedor va a 5-6 Mbps, o sea que **nadie nota el limite
reproduciendo**: lo unico que se corta es la rafaga de precarga, que es
justamente la que satura el puerto. Y el arranque —la parte donde la espera
se nota— va sin tope en ambos carriles.

Al free ademas el corte de rafaga no le duele porque el anuncio ya le tapa el
arranque (la app precarga durante el rewarded).

> **No es seguridad.** La cabecera se puede falsificar con un `curl`. Solo hace
> falta que el cliente honesto se clasifique bien. Si algun dia hace falta que
> sea infalsificable, hay que firmarla (HMAC con la clave de la app).

---

## 1. Requisito de version

`limit_rate` y `limit_rate_after` aceptan variables desde **nginx 1.17**.
Comproba antes de tocar nada:

```bash
nginx -v
```

Si sale 1.16 o menor, para y avisame: hay que hacerlo con `map` a valores fijos
y `if`, que es mas fragil.

---

## 2. Subir la config

Desde tu PC:

```bash
scp "C:\Users\Juan Arrieta\Downloads\bump_comba\vps\nginx-cache-vod.conf" root@217.216.80.212:/etc/nginx/conf.d/vod.conf
```

En el VPS:

```bash
nginx -t && systemctl reload nginx
```

---

## 3. Comprobar que los dos carriles existen

`nginx -t` **no** detecta todos los fallos de este archivo (ver la nota de la
CAPA 2 sobre slice + redirect). Hay que probar con trafico real. Cambia
`USUARIO` y `CLAVE` por las del proveedor:

```bash
curl -s -o /dev/null -w "premium: %{speed_download} B/s  http=%{http_code}\n" -H "X-Bump-Tier: p" -H "Range: bytes=0-52428799" "http://127.0.0.1/movie/USUARIO/CLAVE/759711.mkv"
```

```bash
curl -s -o /dev/null -w "free:    %{speed_download} B/s  http=%{http_code}\n" -H "X-Bump-Tier: f" -H "Range: bytes=0-52428799" "http://127.0.0.1/movie/USUARIO/CLAVE/759711.mkv"
```

Los dos tienen que dar `http=206`. Pidiendo 50 MB (bastante mas que el
`limit_rate_after` de los dos carriles) la velocidad media del free tiene que
salir claramente por debajo de la del premium. Si salen iguales, la cabecera no
esta llegando: revisa que el `map` quedo en el contexto `http` y no dentro del
`server`.

---

## 4. Ver el reparto en hora pico

```bash
ss -tn state established '( sport = :80 )' | wc -l
```

```bash
tail -f /var/log/nginx/error.log | grep -i "prematurely closed"
```

Si los `prematurely closed` bajan despues de este cambio, el diagnostico era
correcto y el siguiente escalon es subirle el tope al premium. Si no bajan, el
problema no es el reparto sino el volumen total, y toca la decision pendiente:
dejar de proxear el video por el VPS.

---

## 5. Ajustar los topes

Estan en los `map` del principio de `vod.conf`:

```
map $http_x_bump_tier $tope_video {
    default   "1000k";   # free
    "p"       "2500k";   # premium
}
```

Regla rapida: `25 MB/s de puerto / tope en MB/s` = cuantos streams simultaneos
caben en ese carril a tope. Con 1000k el free llena el puerto con ~25 streams
simultaneos maximos, pero en la practica casi ninguno va a tope todo el rato.
Bajar el free antes que subir el premium.

## 6. Nada de `limit_conn` (y por que)

La primera version llevaba `limit_conn video_por_ip 4`. Se saco:

1. **TurboProxy abre varias conexiones para UN solo stream** — escala a 3 y
   luego a 4 piernas, con techo de 8. Con el limite en 4, la reproduccion
   normal de un unico usuario ya agotaba la cuota y las piernas de mas
   recibian 503.
2. **`$binary_remote_addr` es la IP publica.** Detras del CGNAT de un movil la
   comparten docenas de usuarios sin relacion entre si: el primero agota el
   limite y el resto come 503 sin haber hecho nada.

Un 503 a un usuario legitimo es peor que un abusador llevandose ancho de banda,
y para el abusador ya esta `limit_rate`. Si alguna vez hace falta reactivarlo,
tiene que ser >= 16 (8 piernas x 2 dispositivos) y sabiendo que el CGNAT lo
comparte.
