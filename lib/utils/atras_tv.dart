/// El "atrás" del mando, filtrado.
///
/// ── UNA PULSACIÓN QUE LLEGA DOS VECES ──────────────────────────────────────
///
/// En el Chromecast el "atrás" llega por un solo camino. El mando de un Xiaomi
/// manda LOS DOS con una sola pulsación: la tecla `goBack` que lee la pantalla
/// y el "atrás" de Android que recoge el `PopScope`.
///
/// Dentro del reproductor eso se arreglaba con un cerrojo suyo, pero no basta:
/// cuando llega el segundo aviso, el reproductor YA SE CERRÓ, así que el eco
/// aterriza en la ficha de detrás —que no sabe nada de todo esto— y la cierra
/// también. Se veía como "salgo del video y me planta en el catálogo",
/// saltándose la ficha, y solo en ese televisor.
///
/// Por eso el filtro vive FUERA de las pantallas: lo que hay que reconocer es
/// que dos avisos seguidos son el MISMO gesto, y eso no se puede saber desde
/// una sola pantalla.
class AtrasTv {
  AtrasTv._();

  /// Cuándo se atendió el último "atrás".
  static DateTime? _ultimo;

  /// Medio segundo: por debajo de eso no hay dedo humano que pulse dos veces
  /// a propósito, y por encima quedan fuera los ecos del sistema, que llegan
  /// en milisegundos.
  static const Duration _ventana = Duration(milliseconds: 500);

  /// `true` si este aviso es el eco del anterior y hay que ignorarlo.
  ///
  /// Quien lo llama y recibe `false` es quien atiende el "atrás": queda
  /// anotado, así que el aviso gemelo que venga detrás —en esta pantalla o en
  /// la de debajo— se descarta solo.
  static bool esEco() {
    final ahora = DateTime.now();
    final previo = _ultimo;
    if (previo != null && ahora.difference(previo) < _ventana) return true;
    _ultimo = ahora;
    return false;
  }
}
