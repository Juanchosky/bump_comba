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

  const TvLoadingAnimation({this.size = 60, this.strokeWidth = 4});

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
