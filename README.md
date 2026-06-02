flutter build apk --release / flutter build appbundle --release / flutter clean / flutter pub get / flutter pub outdated / flutter pub upgrade / -------------------------------------/

RECORDAR QUE AL BORRAR EL ARCHIVO COMPLETO DE BUMP COMBA SE BORRARÁ LO DEL ARCHIVO .env guardar en otro lado.


Edité el ad_service.dart:
Agregué un interruptor al inicio de la clase AdService:
static const bool kBypassAdGateForTesting = true;

cuando está en true, la app reproduce directo (igual que si fueras Premium), sin mostrar el diálogo de anuncio ni el modo "Sin conexión".
⚠️ Importante para cuando publiques
Antes de subir la app a producción, cambia el flag a false:

static const bool kBypassAdGateForTesting = false;
