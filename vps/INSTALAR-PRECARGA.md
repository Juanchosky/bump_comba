# Precarga nocturna de la caché

Descarga de madrugada el arranque de los estrenos más recientes, para que
cuando tus usuarios los busquen ya estén en la caché del VPS.

---

## 1. Subir el script

Desde tu PC (una sola línea):

```bash
scp "C:\Users\Juan Arrieta\Downloads\bump_comba\vps\precarga.sh" root@217.216.80.212:/usr/local/bin/precarga.sh
```

## 2. Crear el archivo de configuración

En el VPS (`ssh root@217.216.80.212`). **Cambiá `TU_CLAVE`** por la contraseña
real del proveedor:

```bash
cat > /etc/precarga.conf <<'FIN'
USUARIO=w5vWTYWMYv
CLAVE=TU_CLAVE
CANTIDAD=30
MB=250
PARALELO=2
MAX_DISCO=85
MAX_HORAS=4
FIN
chmod 600 /etc/precarga.conf
chmod +x /usr/local/bin/precarga.sh
```

> `chmod 600` deja el archivo legible sólo por root: ahí van tus credenciales.

## 3. Probar antes de automatizar

Corré una versión chica para ver que funciona:

```bash
CANTIDAD=3 MB=50 bash -c 'sed -i "s/^CANTIDAD=.*/CANTIDAD=3/;s/^MB=.*/MB=50/" /etc/precarga.conf; /usr/local/bin/precarga.sh; sed -i "s/^CANTIDAD=.*/CANTIDAD=30/;s/^MB=.*/MB=250/" /etc/precarga.conf'
cat /var/log/precarga.log
```

Tenés que ver algo así:

```
=== inicio (cantidad=3 mb=50 paralelo=2) ===
catalogo leido: 3 titulos a precargar
  ok   759711.mkv  (50 MB)
  ok   754414.mkv  (50 MB)
  ok   758002.mkv  (50 MB)
=== fin: 3 titulos | cache=1.2G | disco=6% ===
```

Si ves `FALLA` con un código HTTP, pasámelo.

## 4. Programarlo a las 3 AM

```bash
echo '0 3 * * * root /usr/local/bin/precarga.sh' > /etc/cron.d/precarga
chmod 644 /etc/cron.d/precarga
```

Listo. Se ejecuta solo todas las noches.

---

## Cómo ajustar los números

| Ajuste | Qué hace | Cuándo cambiarlo |
|---|---|---|
| `CANTIDAD` | Cuántos estrenos precarga | Subilo si tenés disco de sobra |
| `MB` | Cuánto de cada película | 250 MB ≈ los primeros 15-20 min |
| `PARALELO` | Conexiones simultáneas | **Dejalo en 2** hasta comprar más conexiones |
| `MAX_DISCO` | % de disco donde se detiene | Bajalo si querés más margen |
| `MAX_HORAS` | Corte de seguridad | Para que no siga de día |

Con los valores por defecto: **30 × 250 MB ≈ 7,5 GB por noche**, en unas 2 horas.

## Por qué sólo el arranque y no la película entera

Con 70 GB de caché no entran 30 películas completas, y el momento crítico es
el arranque: es cuando el usuario decide si "no carga". Con los primeros
15-20 minutos en caché, el resto alcanza a descargarse mientras se reproduce.

## Por qué `PARALELO=2`

Tu línea permite **3 conexiones simultáneas**. Dejando una libre, si alguien
mira algo a las 3 AM no se queda sin servicio. Cuando compres más conexiones,
subilo.

## Ver cómo viene

```bash
tail -20 /var/log/precarga.log
du -sh /var/cache/vod
```

## Limitación conocida

Sólo precarga **películas**. Las series necesitan una llamada extra por cada
temporada (`get_series_info`) para obtener los IDs de los episodios. Si te
sirve, se puede agregar después.
