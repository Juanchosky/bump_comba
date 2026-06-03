import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

class FadeScalePageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  FadeScalePageRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curve = Curves.easeOutQuart;

          final fadeAnimation = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          );

          final scaleAnimation = Tween<double>(
            begin: 0.92,
            end: 1.0,
          ).animate(CurvedAnimation(parent: animation, curve: curve));

          return FadeTransition(
            opacity: fadeAnimation,
            child: ScaleTransition(scale: scaleAnimation, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 400),
      );
}

class SlideUpPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  SlideUpPageRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(0.0, 1.0);
          const end = Offset.zero;
          final curve = Curves.easeOutQuart;

          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));

          final fadeAnimation = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.2, 1.0, curve: Curves.easeIn),
          );

          return FadeTransition(
            opacity: fadeAnimation,
            child: SlideTransition(
              position: animation.drive(tween),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 500),
      );
}

/// Ruta para ContentDetailScreen: opaque:false para que la pantalla anterior
/// se vea detrás durante el gesto de cierre, con animación de entrada
/// tipo tarjeta (slide-up + fade) — distinta a FadeScalePageRoute.
class ContentDetailPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  ContentDetailPageRoute({required this.page})
    : super(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // En iOS: slide-up tipo tarjeta modal + fade rápido.
          // En Android y otros: fade + scale (igual que FadeScalePageRoute).
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            final slide = Tween<Offset>(
              begin: const Offset(0.0, 0.12),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
            final fade = CurvedAnimation(
              parent: animation,
              curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
            );
            return FadeTransition(
              opacity: fade,
              child: SlideTransition(position: slide, child: child),
            );
          }
          // Android / otras plataformas — animación original.
          final fadeAnimation = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
          );
          final scaleAnimation = Tween<double>(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutQuart),
          );
          return FadeTransition(
            opacity: fadeAnimation,
            child: ScaleTransition(scale: scaleAnimation, child: child),
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      );
}

class MaterialFadePageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  MaterialFadePageRoute({required this.page})
    : super(
        pageBuilder: (context, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      );
}
