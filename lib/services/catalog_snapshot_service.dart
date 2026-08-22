import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_progress.dart';
import '../models/m3u_item.dart';
import '../utils/normalization_utils.dart';
import 'xtream_service.dart';

/// Lector del catálogo pre-horneado que publica el VPS.
///
/// ¿POR QUÉ EXISTE?
/// ----------------
/// Al meter el código, la app le pedía el catálogo entero al panel del
/// proveedor: siete peticiones, 22.48 MB, 21.3 s (medido contra red4tv.lat el
/// 2026-08-22). Y lo hacía CADA teléfono, cada 12 h.
///
/// `vps/catalogo.sh` hace ese trabajo una vez por hora para todos, deja el
/// resultado podado a los seis campos que el parser realmente lee y lo publica
/// comprimido. La app baja eso en su lugar: 1.06 MB para VOD + series, servido
/// en 2.8 ms desde disco (medido en el VPS el 2026-08-22).
///
/// EL SEGUNDO VIAJE ES GRATIS
/// --------------------------
/// Se guarda el ETag de cada archivo. En el siguiente arranque se manda
/// `If-None-Match` y, si el catálogo no cambió, el VPS responde 304 sin cuerpo
/// (0 bytes, 0.5 ms medidos) y se reusa la copia local. Por eso `catalogo.sh`
/// solo reemplaza el archivo cuando el contenido cambia de verdad: si tocara la
/// fecha en cada corrida, el ETag cambiaría cada hora y este ahorro no existiría.
///
/// NUNCA ES OBLIGATORIO
/// --------------------
/// Todos los caminos de fallo devuelven `null`, y quien llama sigue con la ruta
/// de siempre contra el panel. Si el VPS se cae, la app funciona igual —
/// más lenta, como antes, pero funciona. Hacer del VPS un punto único de fallo
/// cambiaría un arranque lento por una app muerta.
class CatalogSnapshotService {
  static final CatalogSnapshotService _instance =
      CatalogSnapshotService._internal();
  factory CatalogSnapshotService() => _instance;
  CatalogSnapshotService._internal();

  /// Versión de formato que esta app entiende (campo `v` del archivo).
  ///
  /// Si algún día el snapshot cambia de forma, el VPS sube este número y las
  /// apps viejas lo rechazan y caen al panel, en vez de malinterpretar los
  /// datos y mostrar un catálogo roto.
  static const int _versionSoportada = 1;

  static const Duration _timeout = Duration(seconds: 20);

  static const String _prefsEtagPrefix = 'catalogo_snapshot_etag_';

  /// Base configurable para poder mover o apagar el snapshot sin publicar una
  /// versión nueva de la app. Vacío = desactivado, se usa siempre el panel.
  String get _baseUrl {
    final v = dotenv.env['CATALOG_SNAPSHOT_URL']?.trim() ?? '';
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  bool get estaConfigurado => _baseUrl.isNotEmpty;

  /// Baja VOD + series y los convierte en items listos para el catálogo.
  ///
  /// Devuelve `null` si el snapshot no se puede usar por cualquier motivo.
  /// No se piden los canales en vivo: están desactivados y la UI los oculta
  /// (misma razón por la que `_fetchXtreamItems` tampoco los pide). El VPS los
  /// publica igual, listos para el día que se reactiven.
  Future<List<M3UItem>?> fetchItems({
    required String host,
    required String user,
    required String pass,
    void Function(DownloadProgress)? onProgress,
  }) async {
    if (!estaConfigurado) return null;

    try {
      int vodBytes = 0;
      int seriesBytes = 0;
      void notificar() {
        onProgress?.call(DownloadProgress(vodBytes + seriesBytes, null));
      }

      final resultados = await Future.wait([
        _bajarLista('vod', (b) {
          vodBytes = b;
          notificar();
        }),
        _bajarLista('series', (b) {
          seriesBytes = b;
          notificar();
        }),
      ]);

      // Si falta cualquiera de las dos, se abandona el snapshot ENTERO. Con una
      // sola lista el usuario vería un catálogo a medias y creería que se le
      // borró contenido; es preferible el camino lento pero completo.
      if (resultados.any((r) => r == null)) {
        debugPrint(
          'CatalogSnapshot: falta alguna lista — se usa el panel directo',
        );
        return null;
      }

      final items = await compute(parseSnapshotEnSegundoPlano, {
        'vod': resultados[0]!,
        'series': resultados[1]!,
        'host': host,
        'user': user,
        'pass': pass,
        'version': _versionSoportada,
      });

      if (items.isEmpty) {
        debugPrint('CatalogSnapshot: 0 items — se usa el panel directo');
        return null;
      }

      debugPrint('CatalogSnapshot: ${items.length} items desde el VPS');
      return items;
    } catch (e) {
      debugPrint('CatalogSnapshot: error ($e) — se usa el panel directo');
      return null;
    }
  }

  /// Baja una lista respetando el ETag. Devuelve el JSON crudo o `null`.
  Future<String?> _bajarLista(
    String nombre,
    void Function(int bytes) onBytes,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final archivo = await _archivoLocal(nombre);
    final etagGuardado = prefs.getString('$_prefsEtagPrefix$nombre');
    final hayCopiaLocal = await archivo.exists();

    try {
      final headers = <String, String>{'Accept': 'application/json'};
      // Solo tiene sentido preguntar "¿cambió?" si además tenemos con qué
      // responder a un 304. Con el ETag guardado pero sin archivo, un 304 nos
      // dejaría sin datos y sin forma de pedirlos de nuevo.
      if (etagGuardado != null && etagGuardado.isNotEmpty && hayCopiaLocal) {
        headers['If-None-Match'] = etagGuardado;
      }

      final res = await http
          .get(Uri.parse('$_baseUrl/$nombre.json'), headers: headers)
          .timeout(_timeout);

      if (res.statusCode == HttpStatus.notModified && hayCopiaLocal) {
        final cuerpo = await archivo.readAsString();
        onBytes(0); // 304: no se transfirió nada, no hay progreso que mostrar
        debugPrint('CatalogSnapshot: $nombre sin cambios (304)');
        return cuerpo;
      }

      if (res.statusCode == HttpStatus.ok && res.bodyBytes.isNotEmpty) {
        final cuerpo = utf8.decode(res.bodyBytes, allowMalformed: true);

        // ── Bytes que viajaron, no bytes descomprimidos ────────────────────
        //
        // `bodyBytes` ya viene descomprimido: el cliente HTTP pide gzip solo y
        // lo deshace antes de entregarlo. Reportar su longitud hacía que el log
        // dijera "4.414.227 bytes" cuando por el cable habían ido 958.075
        // (verificado: content-encoding gzip, content-length 958075). Un log
        // que se equivoca por 4,6x manda a buscar problemas donde no los hay, y
        // este número además alimenta la barra de progreso de la descarga.
        //
        // `content-length` es el tamaño real transferido, comprimido o no.
        final enElCable =
            int.tryParse(res.headers[HttpHeaders.contentLengthHeader] ?? '') ??
            res.bodyBytes.length;
        onBytes(enElCable);
        // El archivo se guarda ANTES que el ETag: si el guardado falla, el
        // ETag viejo sigue vigente y la próxima vez se vuelve a bajar entero.
        // Al revés quedaría un ETag apuntando a un archivo que no existe.
        await archivo.writeAsString(cuerpo, flush: true);
        final etag = res.headers['etag'];
        if (etag != null && etag.isNotEmpty) {
          await prefs.setString('$_prefsEtagPrefix$nombre', etag);
        }
        debugPrint(
          'CatalogSnapshot: $nombre bajado ($enElCable bytes en el cable, '
          '${res.bodyBytes.length} descomprimidos)',
        );
        return cuerpo;
      }

      debugPrint('CatalogSnapshot: $nombre HTTP ${res.statusCode}');
    } catch (e) {
      debugPrint('CatalogSnapshot: $nombre falló ($e)');
    }

    // El VPS no contestó o contestó mal. Una copia local vieja sigue siendo
    // mejor que nada: el contenido de ayer se ve igual de bien y evita el
    // arranque lento contra el panel.
    if (hayCopiaLocal) {
      try {
        final cuerpo = await archivo.readAsString();
        debugPrint('CatalogSnapshot: $nombre — se reusa la copia local');
        return cuerpo;
      } catch (_) {}
    }
    return null;
  }

  Future<File> _archivoLocal(String nombre) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/snapshot_$nombre.json');
  }

  /// Borra las copias locales y sus ETags. Para el botón de recarga forzada.
  Future<void> limpiarCache() async {
    final prefs = await SharedPreferences.getInstance();
    for (final nombre in ['vod', 'series', 'live']) {
      await prefs.remove('$_prefsEtagPrefix$nombre');
      try {
        final f = await _archivoLocal(nombre);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}

/// Convierte el snapshot en items. Corre en un isolate (`compute`).
///
/// El formato es deliberadamente escueto —`i n e c l d`— porque el nombre de
/// cada campo se repite en los ~20.000 registros. Ver `vps/catalogo.sh`.
List<M3UItem> parseSnapshotEnSegundoPlano(Map<String, dynamic> input) {
  // Sin barra final: el camino del panel construye las URLs con `cleanHost`
  // (ver fetchVodStreams en xtream_service.dart). Pasar el host con barra
  // producia `http://servidor//movie/...`, que no es la misma URL — y la URL es
  // la clave con la que se guardan favoritos e historial.
  final String hostCrudo = input['host'];
  final String host =
      hostCrudo.endsWith('/')
          ? hostCrudo.substring(0, hostCrudo.length - 1)
          : hostCrudo;
  final String user = input['user'];
  final String pass = input['pass'];
  final int versionSoportada = input['version'];

  // Mismo pooling de cadenas que usan los parsers del panel: las categorías se
  // repiten miles de veces y sin esto cada item se lleva su propia copia.
  final pool = <String, String>{};
  String intern(String s) => pool.putIfAbsent(s, () => s);

  Map<String, dynamic>? abrir(String crudo) {
    final decoded = json.decode(crudo);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['v'] != versionSoportada) return null;
    return decoded;
  }

  final vod = abrir(input['vod']);
  final series = abrir(input['series']);
  // Versión desconocida o forma inesperada: se rechaza entero para que quien
  // llama caiga al panel, en vez de construir un catálogo a medias.
  if (vod == null || series == null) return [];

  final items = <M3UItem>[];

  // ── Las categorías se normalizan AQUÍ, igual que en el panel ─────────────
  //
  // El camino del panel pasa cada nombre por `NormalizationUtils
  // .normalizeCategory` antes de armar el mapa (xtream_service.dart:391), que
  // repara mojibake, quita etiquetas técnicas y aplica Title Case:
  // "CINE DE ORO MEXICANO" -> "Cine de oro mexicano".
  //
  // El snapshot las guarda crudas a propósito (el archivo del VPS no debe
  // decidir cómo se ven las cosas), así que la normalización tiene que pasar
  // aquí. Sin esto, TODAS las categorías cambiaban de nombre respecto al camino
  // del panel, y con ellas el agrupado, el orden por prioridad, las sagas y los
  // filtros — que es exactamente como se ve "muchos contenidos no salen".
  //
  // Se llama a la MISMA función, no a una copia: si algún día cambia, los dos
  // caminos cambian juntos.
  Map<String, String> categoriasDe(Map<String, dynamic> raiz) {
    final c = raiz['categorias'];
    if (c is! Map) return const {};
    return c.map(
      (k, v) => MapEntry(
        k.toString(),
        NormalizationUtils.normalizeCategory(v.toString()),
      ),
    );
  }

  // ── Películas ────────────────────────────────────────────────────────────
  final catsVod = categoriasDe(vod);
  final listaVod = vod['items'];
  if (listaVod is List) {
    for (final raw in listaVod) {
      if (raw is! Map) continue;
      final id = raw['i']?.toString();
      if (id == null || id.isEmpty) continue;
      final nombre = raw['n']?.toString() ?? 'Sin nombre';
      // La extensión por defecto es la misma que usa el parser del panel: el
      // snapshot omite el campo cuando el proveedor no lo manda.
      final ext = raw['e']?.toString() ?? 'mp4';
      final catId = raw['c']?.toString() ?? '';

      items.add(
        M3UItem(
          name: nombre,
          // La URL se arma AQUÍ, en el teléfono, con las credenciales de este
          // usuario. Por eso el archivo del VPS puede ser el mismo para todos
          // y no lleva ninguna credencial dentro.
          url: '$host/movie/$user/$pass/$id.$ext',
          logo: fixXtreamLogo(raw['l']?.toString(), nombre, host),
          category: intern(catsVod[catId] ?? 'Películas'),
          isLive: false,
          duration: raw['d']?.toString(),
        ),
      );
    }
  }

  // ── Series ───────────────────────────────────────────────────────────────
  // La app guarda el series_id en `url` y con eso pide los episodios después
  // (fetchSeriesEpisodes). No es una URL reproducible, y así era ya en el
  // parser del panel.
  final catsSeries = categoriasDe(series);
  final listaSeries = series['items'];
  if (listaSeries is List) {
    for (final raw in listaSeries) {
      if (raw is! Map) continue;
      final id = raw['i']?.toString();
      if (id == null || id.isEmpty) continue;
      final nombre = raw['n']?.toString() ?? 'Sin nombre';
      final catId = raw['c']?.toString() ?? '';

      items.add(
        M3UItem(
          name: nombre,
          url: id,
          logo: fixXtreamLogo(raw['l']?.toString(), nombre, host),
          category: intern(catsSeries[catId] ?? 'Series'),
          isLive: false,
          isSeries: true,
          seriesName: intern(nombre),
          episodes: [],
        ),
      );
    }
  }

  return items;
}
