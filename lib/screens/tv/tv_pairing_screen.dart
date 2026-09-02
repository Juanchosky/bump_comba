import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/tv/tv_pairing_service.dart';

/// Pantalla de vinculación del televisor.
///
/// ESTRUCTURA PRESTADA DE NETFLIX
/// Marca arriba a la derecha, título centrado arriba, y el contenido repartido
/// en DOS PANELES: a la izquierda lo que hay que hacer, a la derecha el dato
/// grande. Es la misma forma que su pantalla de inicio de sesión en televisor,
/// y funciona por un motivo concreto: en una tele el ojo barre en horizontal,
/// no en vertical. Una columna centrada obliga a leer de arriba abajo saltando
/// el foco; dos paneles se abarcan de una mirada.
///
/// AQUÍ NO SE TECLEA NADA
/// Netflix necesita un teclado en pantalla porque pide correo y contraseña.
/// Nosotros no: el código se lee aquí y se escribe en el teléfono, que ya tiene
/// teclado y ya sabe quién eres. Por eso el panel derecho enseña y no pide.
class TvPairingScreen extends StatefulWidget {
  /// Se llama cuando el televisor queda vinculado.
  final VoidCallback onVinculado;

  const TvPairingScreen({super.key, required this.onVinculado});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  String? _codigo;
  DateTime? _expira;
  String? _error;
  Timer? _sondeo;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _pedir();
  }

  @override
  void dispose() {
    _sondeo?.cancel();
    _reloj?.cancel();
    super.dispose();
  }

  Future<void> _pedir() async {
    setState(() {
      _error = null;
      _codigo = null;
    });

    final r = await TvPairingService.instance.pedirCodigo(
      nombreAparato: 'Televisor',
    );
    if (!mounted) return;

    if (r == null) {
      setState(() => _error = 'No hay conexión con el servidor.');
      return;
    }

    setState(() {
      _codigo = r.codigo;
      _expira = r.expira;
    });

    // Cada 3 s. Más a menudo no acelera nada perceptible —el usuario tarda en
    // teclear— y multiplica llamadas por cada televisor que deje esta pantalla
    // abierta y se vaya a cenar.
    _sondeo?.cancel();
    _sondeo = Timer.periodic(const Duration(seconds: 3), (_) => _consultar());

    _reloj?.cancel();
    _reloj = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _consultar() async {
    final codigo = _codigo;
    if (codigo == null) return;

    final estado = await TvPairingService.instance.consultarEstado(codigo);
    if (!mounted) return;

    if (estado == 'vinculado') {
      _sondeo?.cancel();
      _reloj?.cancel();
      widget.onVinculado();
      return;
    }
    // Caducado o desaparecido: se pide otro solo, sin que el usuario tenga que
    // entender qué pasó ni buscar un botón.
    if (estado == 'caducado' || estado == 'desconocido') {
      _sondeo?.cancel();
      await _pedir();
    }
  }

  String get _restante {
    final e = _expira;
    if (e == null) return '';
    final s = e.difference(DateTime.now()).inSeconds;
    if (s <= 0) return '';
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Un rojo muy apagado arriba a la derecha, detrás de la marca. Es lo
          // único que separa esto de un fondo negro plano, y basta.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.85, -0.9),
                radius: 1.1,
                colors: [Color(0x33B71C1C), Colors.transparent],
              ),
            ),
            child: SizedBox.expand(),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(64, 34, 64, 34),
            child: Column(
              children: [
                // ── Cabecera: título centrado, marca a la derecha ──────────
                SizedBox(
                  height: 46,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        'Activa tu televisor',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 30),

                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ── Panel izquierdo: qué hacer ────────────────────────
                      Expanded(child: _panelPasos()),

                      // Separador vertical, como el de Netflix entre las dos
                      // mitades.
                      Container(
                        width: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 44),
                        color: Colors.white.withValues(alpha: 0.09),
                      ),

                      // ── Panel derecho: el código ──────────────────────────
                      Expanded(child: _panelCodigo()),
                    ],
                  ),
                ),

                const SizedBox(height: 18),
                Text(
                  _error == null
                      ? 'Esta pantalla se cierra sola en cuanto lo escribas  ·  '
                          'Atrás para volver'
                      : 'Atrás para volver',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.22),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelPasos() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'EN TU TELÉFONO',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.4,
          ),
        ),
        const SizedBox(height: 26),
        _paso(1, 'Abre Bump Comba'),
        _paso(2, 'Entra en Ajustes\ndel navegador de contenido'),
        _paso(3, 'Toca "Vincular televisor"'),
        _paso(4, 'Escribe el código de al lado', ultimo: true),
      ],
    );
  }

  Widget _paso(int n, String texto, {bool ultimo = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: ultimo ? 0 : 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              '$n',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                texto,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelCodigo() {
    if (_error != null) return _panelError();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CÓDIGO',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.4,
          ),
        ),
        const SizedBox(height: 22),

        if (_codigo == null)
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 3, color: Colors.red),
          )
        else ...[
          // El código dentro de su propio recuadro: es EL dato de la pantalla,
          // y enmarcarlo dice dónde mirar sin necesidad de una flecha.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            // FittedBox y `softWrap: false`: el codigo va en UNA linea,
            // pase lo que pase.
            //
            // A cuerpo fijo se partia en dos ("4XVY-" / "AGJE") en cuanto el
            // panel se quedaba corto, y un codigo partido se lee mal y se
            // teclea peor: el guion al final de la primera linea parece un
            // caracter mas. Asi se encoge lo justo para caber y nunca se
            // rompe.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _codigo!,
                softWrap: false,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 52,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 7,
                  height: 1.0,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          if (_restante.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 15,
                  color: Colors.white.withValues(alpha: 0.3),
                ),
                const SizedBox(width: 7),
                Text(
                  'Caduca en $_restante',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  Widget _panelError() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _BotonReintentar(onOk: _pedir),
      ],
    );
  }
}

/// Único control de la pantalla, así que pide el foco al aparecer.
///
/// Sin `autofocus` no habría forma de llegar hasta él: el `Focus` que envuelve
/// esta pantalla ocupa todo el alto, y la navegación direccional de Flutter no
/// sabe moverse desde un rectángulo que lo abarca todo.
class _BotonReintentar extends StatefulWidget {
  final VoidCallback onOk;
  const _BotonReintentar({required this.onOk});

  @override
  State<_BotonReintentar> createState() => _BotonReintentarState();
}

class _BotonReintentarState extends State<_BotonReintentar> {
  bool _foco = false;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: true,
      onShowFocusHighlight: (v) => setState(() => _foco = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onOk();
            return null;
          },
        ),
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 12),
        decoration: BoxDecoration(
          color: _foco ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white54, width: 2),
        ),
        child: Text(
          'Reintentar',
          style: TextStyle(
            color: _foco ? Colors.black : Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
