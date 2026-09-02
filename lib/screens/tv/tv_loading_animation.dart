import 'dart:math' as math;

import 'package:flutter/material.dart';

/// El spinner de la app, compartido por el receptor y el reproductor autonomo
/// del televisor.
///
/// Vive aqui y no dentro de una pantalla porque los dos tienen que enseñar
/// EXACTAMENTE el mismo: al transmitir salia este y al abrir desde el catalogo
/// salia el `CircularProgressIndicator` de Material. Dos esperas distintas para
/// la misma app se notan enseguida y restan.
class TvLoadingAnimation extends StatefulWidget {
  final double size;
  final double strokeWidth;

  const TvLoadingAnimation({super.key, this.size = 60, this.strokeWidth = 4});

  @override
  State<TvLoadingAnimation> createState() => TvLoadingAnimationState();
}

class TvLoadingAnimationState extends State<TvLoadingAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.1),
                width: widget.strokeWidth,
              ),
            ),
          ),
          SizedBox(
            width: widget.size,
            height: widget.size,
            child: CircularProgressIndicator(
              value: 0.3,
              strokeWidth: widget.strokeWidth,
              color: Colors.red,
              strokeCap: StrokeCap.round,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pregunta a pantalla completa en el televisor, contestable con el mando.
///
/// Tamanos pensados para verse desde el sofa: el titulo a 34 y los botones a
/// 22, muy por encima de lo que se usaria en un telefono. El foco se marca con
/// relleno solido y borde, no solo con color, porque a tres metros un cambio de
/// tono no se distingue.

/// La espera con la marca de la app: el logo sobre negro, latiendo despacio.
///
/// ── POR QUE NO UNA RUEDA GIRANDO ───────────────────────────────────────────
///
/// Estaba el `CircularProgressIndicator` de Material y se veia como una
/// pantalla del sistema operativo, no como la app. Un indicador de progreso
/// ademas promete que algo avanza, y una rueda dando vueltas no dice cuanto
/// queda: solo llena el hueco.
///
/// ── POR QUE VIVE AQUI Y NO DENTRO DE UNA PANTALLA ──────────────────────────
///
/// La usan DOS esperas distintas: la del catalogo mientras trae el contenido y
/// la del receptor mientras comprueba si el televisor esta vinculado. Si cada
/// una tuviera la suya, acabarian pareciendose solo un rato — que es como
/// empezo el problema del spinner.
class TvPantallaMarca extends StatefulWidget {
  const TvPantallaMarca({super.key});

  @override
  State<TvPantallaMarca> createState() => _TvPantallaMarcaState();
}

class _TvPantallaMarcaState extends State<TvPantallaMarca>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulso = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulso.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: FadeTransition(
          // Entre 0.45 y 1: se nota el latido sin llegar a parpadear. Lento a
          // proposito —1,4 s por ciclo—; rapido transmite prisa, y aqui lo que
          // toca es esperar.
          opacity: Tween<double>(
            begin: 0.45,
            end: 1.0,
          ).animate(CurvedAnimation(parent: _pulso, curve: Curves.easeInOut)),
          child: Image.asset(
            'assets/images/logo.png',
            height: 96,
            // Si el logo faltara, la pantalla no puede quedarse en blanco.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
