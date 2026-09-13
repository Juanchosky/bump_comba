import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Spinner de estilo iOS (CupertinoActivityIndicator), compartido por el
/// receptor y el reproductor autónomo del televisor.
class TvLoadingAnimation extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const TvLoadingAnimation({
    super.key,
    this.size = 60,
    this.strokeWidth = 4,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Escala del radio adaptada para verse nítida y perfectamente legible a distancia de sofá:
    final radius = (size * 0.44).clamp(14.0, 38.0);
    return CupertinoActivityIndicator(
      radius: radius,
      color: color ?? Colors.white,
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
