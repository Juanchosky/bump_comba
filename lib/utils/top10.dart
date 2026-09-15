import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/m3u_item.dart';

/// El "Top 10 películas hoy", compartido por el teléfono y el televisor.
///
/// Vivía dentro de la pantalla del teléfono. Al llevarlo al televisor se saca
/// aquí para que las dos pantallas enseñen LOS MISMOS diez títulos el mismo
/// día: dos copias del algoritmo acabarían diferenciándose.
///
/// El algoritmo es el de siempre: de las primeras 500 películas, las del año
/// más reciente que aparece en el título (y las del anterior si hay menos de
/// 15), barajadas con una semilla que es la FECHA. Así el ranking cambia cada
/// día pero no en cada repintado.
List<M3UItem> top10Peliculas(List<M3UItem> peliculas) {
  final pool = peliculas.take(500).toList();
  if (pool.isEmpty) return const [];

  final conAnio = <(M3UItem, int)>[];
  for (final item in pool) {
    final anio = anioDelTitulo(item.name);
    if (anio != null) conAnio.add((item, anio));
  }

  var maximo = 0;
  for (final e in conAnio) {
    if (e.$2 > maximo) maximo = e.$2;
  }

  var filtrado = conAnio.where((e) => e.$2 == maximo).map((e) => e.$1).toList();
  if (filtrado.length < 15 && maximo > 1900) {
    filtrado.addAll(conAnio.where((e) => e.$2 == maximo - 1).map((e) => e.$1));
  }
  if (filtrado.isEmpty) filtrado = pool.take(100).toList();

  final hoy = DateTime.now();
  final semilla = hoy.year * 10000 + hoy.month * 100 + hoy.day;
  return (List<M3UItem>.from(filtrado)..shuffle(Random(semilla)))
      .take(10)
      .toList();
}

/// El año de un título: el último número de 4 cifras entre 1900 y 2100.
int? anioDelTitulo(String nombre) {
  final m = RegExp(r'(?:[\[\(]?)(\d{4})(?:[\]\)]?)').allMatches(nombre);
  if (m.isEmpty) return null;
  final anio = int.tryParse(m.last.group(1) ?? '');
  return (anio != null && anio >= 1900 && anio <= 2100) ? anio : null;
}

/// "Top 10 películas en Colombia hoy", o sin país si no se conoce.
String tituloTop10(String? codigoPais) {
  final pais = nombrePais(codigoPais ?? '');
  return pais.isEmpty ? 'Top 10 películas hoy' : 'Top 10 películas en $pais hoy';
}

String nombrePais(String codigo) {
  const paises = {
    'AR': 'Argentina',
    'BO': 'Bolivia',
    'BR': 'Brasil',
    'CL': 'Chile',
    'CO': 'Colombia',
    'CR': 'Costa Rica',
    'CU': 'Cuba',
    'EC': 'Ecuador',
    'ES': 'España',
    'GT': 'Guatemala',
    'HN': 'Honduras',
    'MX': 'México',
    'NI': 'Nicaragua',
    'PA': 'Panamá',
    'PY': 'Paraguay',
    'PE': 'Perú',
    'PR': 'Puerto Rico',
    'DO': 'República Dominicana',
    'SV': 'El Salvador',
    'UY': 'Uruguay',
    'VE': 'Venezuela',
    'US': 'Estados Unidos',
  };
  return paises[codigo.toUpperCase()] ?? '';
}

String? _paisDetectado;
Future<String?>? _deteccionEnCurso;

/// País por IP (una sola consulta por sesión, compartida). Los televisores
/// suelen venir con el idioma del sistema en inglés/EE. UU., así que el país
/// del `locale` no sirve para el título.
Future<String?> detectarPais() {
  if (_paisDetectado != null) return Future.value(_paisDetectado);
  return _deteccionEnCurso ??= () async {
    try {
      final r = await http
          .get(Uri.parse('http://ip-api.com/json'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) {
        final data = jsonDecode(r.body);
        if (data['status'] == 'success' && data['countryCode'] != null) {
          _paisDetectado = data['countryCode'].toString().toUpperCase();
        }
      }
    } catch (_) {}
    _deteccionEnCurso = null;
    return _paisDetectado;
  }();
}
