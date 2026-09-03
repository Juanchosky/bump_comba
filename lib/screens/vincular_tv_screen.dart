import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/premium_service.dart';
import '../services/tv/tv_pairing_service.dart';
import '../utils/colors.dart';

/// Pantalla del teléfono para vincular un televisor.
///
/// Es la mitad que hace el trabajo: el televisor solo enseña un código, y aquí
/// se escribe. Se hace en este sentido porque es donde hay teclado y donde vive
/// la suscripción — teclear ocho caracteres con un mando es un castigo, y el
/// televisor no tiene forma de saber por sí mismo quién es premium.
///
/// EL ESTILO ES EL DE LA CONFIGURACIÓN, NO EL DE MATERIAL POR DEFECTO
/// Se llega aquí desde los ajustes del navegador, así que usa sus mismas
/// piezas: fondo `AppColors.background`, cabeceras de sección en rojo y
/// mayúsculas, tarjetas de blanco al 5% con borde al 8% y radio 16, e iconos
/// dentro de un cuadrado redondeado. Una pantalla con `Card` y botones de
/// Material se nota como de otra app en cuanto se abre.
///
/// EL CÓDIGO SE ESCRIBE EN CASILLAS, NO EN UNA CAJA DE TEXTO
/// Ocho caracteres en un `TextField` corriente no dicen cuántos faltan, y con
/// el guion metiéndose solo el cursor parecía saltar. Las casillas enseñan de
/// un vistazo la longitud, cuál toca ahora y cuánto queda, que es justo lo que
/// se pregunta quien está copiando algo de una pantalla al otro lado del
/// salón. Debajo sigue habiendo un `TextField` de verdad —invisible— porque
/// reescribir el teclado, el pegado y el autocompletado a mano sale mal.
class VincularTvScreen extends StatefulWidget {
  const VincularTvScreen({super.key});

  @override
  State<VincularTvScreen> createState() => _VincularTvScreenState();
}

class _VincularTvScreenState extends State<VincularTvScreen> {
  static const int _largoCodigo = 8;

  final _controlador = TextEditingController();
  final _foco = FocusNode();

  bool _enviando = false;
  bool _cargandoLista = true;
  String? _mensaje;
  bool _exito = false;

  List<Map<String, dynamic>> _televisores = const [];
  int _max = 2;
  ({String ref, String kind})? _identidad;

  @override
  void initState() {
    super.initState();
    // Las casillas marcan cuál toca solo con el teclado abierto, así que hay
    // que repintarlas cuando el foco entra o sale.
    _foco.addListener(_alCambiarFoco);
    _cargar();
  }

  void _alCambiarFoco() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _foco.removeListener(_alCambiarFoco);
    _foco.dispose();
    _controlador.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    final id = await PremiumService().identidadParaTv();
    if (!mounted) return;
    _identidad = id;

    if (id == null) {
      setState(() => _cargandoLista = false);
      return;
    }
    final r = await TvPairingService.instance.listarTelevisores(id.ref);
    if (!mounted) return;
    setState(() {
      _televisores = r.lista;
      _max = r.max;
      _cargandoLista = false;
    });
  }

  Future<void> _vincular() async {
    final id = _identidad;
    final crudo = _controlador.text.trim().toUpperCase();
    // El código se manda solo al llegar al octavo carácter, y también con el
    // botón: sin esta guarda las dos vías canjearían el mismo código dos veces
    // y la segunda volvería con «ya se usó».
    if (_enviando || id == null || crudo.length < _largoCodigo) return;

    // El servidor reparte los códigos con guion (`K7F2-9QXA`) y así los enseña
    // el televisor, así que se manda con guion aunque aquí se guarde limpio.
    final codigo = '${crudo.substring(0, 4)}-${crudo.substring(4)}';

    _foco.unfocus();
    setState(() {
      _enviando = true;
      _mensaje = null;
      _exito = false;
    });

    final r = await TvPairingService.instance.canjear(
      codigo: codigo,
      userRef: id.ref,
      userKind: id.kind,
    );
    if (!mounted) return;

    setState(() {
      _enviando = false;
      _exito = r.ok;
      _mensaje =
          r.ok
              ? 'Televisor vinculado'
              : TvPairingService.explicar(r.motivo, max: r.max);
    });

    if (r.ok) {
      HapticFeedback.mediumImpact();
      _controlador.clear();
      await _cargar();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _revocar(Map<String, dynamic> tv) async {
    final id = _identidad;
    if (id == null) return;

    final nombre = _nombreDe(tv);

    // Se pregunta en una hoja inferior, no en un `AlertDialog`: es la misma
    // pieza con la que la configuración confirma borrar una fuente, y esta
    // pantalla se abre justo desde allí.
    final confirmado = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder:
          (c) => _HojaInferior(
            titulo: '¿Quitar «$nombre»?',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Text(
                    'Dejará de mostrar el contenido y tendrás que vincularlo '
                    'otra vez si cambias de idea.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: _BotonHoja(
                          etiqueta: 'Cancelar',
                          onTap: () => Navigator.pop(c, false),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _BotonHoja(
                          etiqueta: 'Quitar',
                          onTap: () => Navigator.pop(c, true),
                          peligro: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
    );
    if (confirmado != true) return;

    await TvPairingService.instance.revocar(
      userRef: id.ref,
      id: tv['id'].toString(),
    );
    if (!mounted) return;
    setState(() {
      _mensaje = null;
      _cargandoLista = true;
    });
    await _cargar();
  }

  // ── Piezas prestadas de la pantalla de configuración ─────────────────────
  Widget _cabecera(String titulo) => Text(
    titulo.toUpperCase(),
    style: TextStyle(
      color: Colors.red.withValues(alpha: 0.9),
      fontSize: 11,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.4,
    ),
  );

  Widget _tarjeta(List<Widget> hijos) => Container(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: hijos,
      ),
    ),
  );

  Widget _separador() => Divider(
    height: 1,
    thickness: 1,
    indent: 60,
    color: Colors.white.withValues(alpha: 0.06),
  );

  @override
  Widget build(BuildContext context) {
    final sinSuscripcion = _identidad == null && !_cargandoLista;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Vincular televisor',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          if (sinSuscripcion)
            _bloqueSinSuscripcion()
          else ...[
            const SizedBox(height: 8),
            _cabecera('Cómo se hace'),
            const SizedBox(height: 10),
            _pasos(),

            const SizedBox(height: 24),

            _cabecera('Código del televisor'),
            const SizedBox(height: 10),
            _bloqueCodigo(),

            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child:
                  _mensaje == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _aviso(_mensaje!, _exito),
                      ),
            ),

            const SizedBox(height: 24),

            Row(
              children: [
                _cabecera('Televisores vinculados'),
                const Spacer(),
                _medidorCupo(),
              ],
            ),
            const SizedBox(height: 10),
            _listaTelevisores(),
          ],
        ],
      ),
    );
  }

  // ── Pasos ────────────────────────────────────────────────────────────────
  Widget _pasos() => _tarjeta([
    _paso(
      1,
      'Abre Bump Comba en el televisor',
      'Baja hasta «Activar este televisor».',
    ),
    _separador(),
    _paso(
      2,
      'Copia el código que aparece',
      'Escríbelo aquí abajo. Caduca a los pocos minutos.',
    ),
  ]);

  Widget _paso(int n, String titulo, String detalle) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
          ),
          child: Text(
            '$n',
            style: const TextStyle(
              color: Colors.red,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detalle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  // ── Código ───────────────────────────────────────────────────────────────
  Widget _bloqueCodigo() {
    return _tarjeta([
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controlador,
          builder: (context, valor, _) {
            final texto = valor.text;
            final completo = texto.length == _largoCodigo;

            return Column(
              children: [
                _casillas(texto),
                const SizedBox(height: 18),
                _botonVincular(habilitado: completo && !_enviando),
              ],
            );
          },
        ),
      ),
    ]);
  }

  Widget _casillas(String texto) {
    return GestureDetector(
      onTap: () => _foco.requestFocus(),
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // El campo de verdad, invisible detrás de las casillas: se queda con
          // el teclado, el pegado y la selección, que reimplementados a mano
          // siempre salen peor.
          SizedBox(
            height: 56,
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _controlador,
                focusNode: _foco,
                autofocus: true,
                showCursor: false,
                enableSuggestions: false,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                keyboardType: TextInputType.visiblePassword,
                inputFormatters: [_FormatoCodigo()],
                onChanged: (t) {
                  if (t.length == _largoCodigo) {
                    HapticFeedback.selectionClick();
                    _vincular();
                  }
                },
              ),
            ),
          ),
          IgnorePointer(
            child: Row(
              children: [
                for (int i = 0; i < _largoCodigo; i++) ...[
                  if (i == 4) _guion(),
                  Expanded(child: _casilla(i, texto)),
                  if (i != _largoCodigo - 1 && i != 3) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _guion() => Container(
    width: 16,
    height: 2,
    margin: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(1),
    ),
  );

  Widget _casilla(int i, String texto) {
    final lleno = i < texto.length;
    // La casilla activa solo se marca mientras el campo tiene el foco: con el
    // teclado cerrado, un borde encendido invitaría a escribir donde no se
    // puede.
    final activa = _foco.hasFocus && i == texto.length && !_enviando;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            lleno
                ? Colors.red.withValues(alpha: 0.10)
                : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color:
              activa
                  ? Colors.red
                  : lleno
                  ? Colors.red.withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.08),
          width: activa ? 1.6 : 1,
        ),
      ),
      child: Text(
        lleno ? texto[i] : '',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _botonVincular({required bool habilitado}) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: habilitado || _enviando ? 1 : 0.4,
        child: DecoratedBox(
          // El rojo plano de `Colors.red`, el mismo que los botones primarios
          // de la configuración y de sus hojas inferiores. El degradado que
          // había antes era más saturado y desentonaba con ellos.
          decoration: BoxDecoration(
            color: Colors.red,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: habilitado ? _vincular : null,
              child: Center(
                child:
                    _enviando
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                        : const Text(
                          'Vincular televisor',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Aviso ────────────────────────────────────────────────────────────────
  //
  // El mensaje se parte en titular y explicación. Un párrafo corrido dentro de
  // un recuadro verde se leía como un `SnackBar` olvidado; con el titular en
  // grande se sabe si salió bien sin terminar de leer.
  Widget _aviso(String texto, bool exito) {
    final color = exito ? const Color(0xFF32D74B) : Colors.red;
    final titulo = exito ? '¡Listo!' : 'No se pudo vincular';
    final detalle =
        exito ? 'Ya puedes usar el televisor sin el teléfono.' : texto;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Icon(
              exito
                  ? CupertinoIcons.checkmark_alt
                  : CupertinoIcons.exclamationmark,
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detalle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Televisores ──────────────────────────────────────────────────────────
  //
  // El cupo va en puntos, no en "1 de 2": se ve de un vistazo cuánto queda sin
  // tener que restar.
  Widget _medidorCupo() {
    if (_cargandoLista) return const SizedBox.shrink();
    return Row(
      children: [
        for (int i = 0; i < _max; i++)
          Container(
            width: 14,
            height: 5,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color:
                  i < _televisores.length
                      ? Colors.red
                      : Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        const SizedBox(width: 8),
        Text(
          '${_televisores.length}/$_max',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _listaTelevisores() {
    if (_cargandoLista) {
      return _tarjeta([
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.red,
              ),
            ),
          ),
        ),
      ]);
    }

    if (_televisores.isEmpty) {
      // El vacío es un borde discontinuo, no una tarjeta llena: se lee como un
      // hueco esperando a llenarse en lugar de como una fila rota.
      return DottedBorderBox(
        child: Column(
          children: [
            Icon(
              CupertinoIcons.tv,
              color: Colors.white.withValues(alpha: 0.2),
              size: 30,
            ),
            const SizedBox(height: 10),
            Text(
              'Ningún televisor todavía',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Los que vincules aparecerán aquí.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      );
    }

    return _tarjeta([
      for (int i = 0; i < _televisores.length; i++) ...[
        if (i > 0) _separador(),
        _filaTelevisor(_televisores[i]),
      ],
    ]);
  }

  String _nombreDe(Map<String, dynamic> tv) =>
      (tv['device_name'] as String?)?.trim().isNotEmpty == true
          ? (tv['device_name'] as String).trim()
          : 'Televisor';

  Widget _filaTelevisor(Map<String, dynamic> tv) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.red.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: Colors.red.withValues(alpha: 0.22)),
            ),
            child: const Icon(
              CupertinoIcons.tv_fill,
              color: Colors.red,
              size: 20,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _nombreDe(tv),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFF32D74B),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _visto(tv['last_seen_at'] as String?),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.42),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Quitar',
            icon: Icon(
              CupertinoIcons.xmark,
              color: Colors.white.withValues(alpha: 0.35),
              size: 18,
            ),
            onPressed: () => _revocar(tv),
          ),
        ],
      ),
    );
  }

  // ── Sin suscripción ──────────────────────────────────────────────────────
  Widget _bloqueSinSuscripcion() => Padding(
    padding: const EdgeInsets.only(top: 40),
    child: Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.red.withValues(alpha: 0.25)),
          ),
          child: const Icon(
            CupertinoIcons.lock_fill,
            color: Colors.red,
            size: 30,
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'Necesitas una suscripción',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Con un plan activo puedes ver el contenido directamente en el '
            'televisor, sin el teléfono.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );

  String _visto(String? iso) {
    if (iso == null) return 'Sin usar todavía';
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final dias = DateTime.now().difference(d.toLocal()).inDays;
    if (dias == 0) return 'Visto hoy';
    if (dias == 1) return 'Visto ayer';
    return 'Visto hace $dias días';
  }
}

/// Recuadro de borde discontinuo para el estado vacío.
class DottedBorderBox extends StatelessWidget {
  final Widget child;
  const DottedBorderBox({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _PintorDiscontinuo(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
        child: Center(child: child),
      ),
    );
  }
}

class _PintorDiscontinuo extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pincel =
        Paint()
          ..color = Colors.white.withValues(alpha: 0.12)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(16),
    );
    final camino = Path()..addRRect(rrect);

    for (final metrica in camino.computeMetrics()) {
      var distancia = 0.0;
      while (distancia < metrica.length) {
        final hasta = (distancia + 6).clamp(0.0, metrica.length);
        canvas.drawPath(metrica.extractPath(distancia, hasta), pincel);
        distancia = hasta + 5;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// La misma hoja inferior que usa la configuración para confirmar.
class _HojaInferior extends StatelessWidget {
  final String titulo;
  final Widget child;

  const _HojaInferior({required this.titulo, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
          child,
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _BotonHoja extends StatelessWidget {
  final String etiqueta;
  final VoidCallback onTap;
  final bool peligro;

  const _BotonHoja({
    required this.etiqueta,
    required this.onTap,
    this.peligro = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              peligro
                  ? Colors.red.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color:
                peligro
                    ? Colors.red.withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          etiqueta,
          style: TextStyle(
            color: peligro ? Colors.red : Colors.white.withValues(alpha: 0.6),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Deja solo letras y números en mayúsculas, hasta ocho.
///
/// El guion ya no se escribe: lo dibujan las casillas. Guardar el código limpio
/// evita tener que descontarlo cada vez que se cuenta cuántos caracteres van.
class _FormatoCodigo extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue anterior,
    TextEditingValue nuevo,
  ) {
    final limpio = nuevo.text.toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    final cortado = limpio.length > 8 ? limpio.substring(0, 8) : limpio;

    return TextEditingValue(
      text: cortado,
      selection: TextSelection.collapsed(offset: cortado.length),
    );
  }
}
