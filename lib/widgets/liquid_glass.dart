import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Fondo de cristal con el efecto Liquid Glass REAL de Apple (iOS 26).
///
/// En iOS incrusta una vista nativa (`UIGlassEffect`) mediante [UiKitView].
/// En el resto de plataformas usa un desenfoque aproximado para no romper la UI.
///
/// El [child] (por ejemplo los ítems de la barra) se dibuja por encima del
/// cristal dentro de un [Stack].
class LiquidGlass extends StatelessWidget {
  final double cornerRadius;
  final bool interactive;
  final Widget? child;

  const LiquidGlass({
    super.key,
    this.cornerRadius = 30,
    this.interactive = true,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // El redondeo lo hace Flutter (ClipRRect): el platform view llena el
      // rectángulo y lo de afuera queda transparente, sin borde negro.
      return ClipRRect(
        borderRadius: BorderRadius.circular(cornerRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cristal nativo de Apple.
            UiKitView(
              viewType: 'liquid_glass',
              creationParams: <String, dynamic>{
                'cornerRadius': cornerRadius,
                'interactive': interactive,
              },
              creationParamsCodec: const StandardMessageCodec(),
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            ),
            if (child != null) child!,
          ],
        ),
      );
    }

    // Fallback (no iOS): desenfoque translúcido aproximado.
    return ClipRRect(
      borderRadius: BorderRadius.circular(cornerRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(cornerRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
