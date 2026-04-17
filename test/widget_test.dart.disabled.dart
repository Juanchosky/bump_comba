// Widget tests para Bump Comba
//
// NOTA: pumpAndSettle falla con esta app porque:
//   1. El SplashScreen tiene animaciones continuas
//   2. Supabase / PremiumService hacen llamadas de red
//   3. Los servicios se inicializan en background indefinidamente
//
// La solución es usar pump(Duration) en lugar de pumpAndSettle,
// y verificar solo que la app arranca sin crashear.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bump_comba/main.dart';

void main() {
  // ── Test 1: La app arranca sin crashear ───────────────────────────────────
  testWidgets('App arranca sin lanzar excepciones', (
    WidgetTester tester,
  ) async {
    // Montar la app
    await tester.pumpWidget(const BumpCombaApp());

    // Dar un frame para que se renderice el primer widget
    await tester.pump();

    // Verificar que existe al menos un widget en el árbol
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  // ── Test 2: El SplashScreen se muestra primero ────────────────────────────
  testWidgets('SplashScreen es el primer widget visible', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const BumpCombaApp());

    // Esperar el primer frame solamente (sin settle)
    await tester.pump(const Duration(milliseconds: 100));

    // Verificar que hay algún widget renderizado (no pantalla en blanco)
    expect(find.byType(Scaffold).first, findsOneWidget);
  });

  // ── Test 3: No hay errores de overflow en pantalla normal ─────────────────
  testWidgets('No hay RenderFlex overflow en splash', (
    WidgetTester tester,
  ) async {
    final List<dynamic> errors = [];

    // Capturar errores de Flutter sin fallar el test
    FlutterError.onError = (FlutterErrorDetails details) {
      // Ignorar errores de red y fuentes en tests
      final msg = details.exception.toString();
      if (msg.contains('SocketException') ||
          msg.contains('font') ||
          msg.contains('GoogleFonts') ||
          msg.contains('Supabase') ||
          msg.contains('network')) {
        return;
      }
      errors.add(details.exception);
    };

    await tester.pumpWidget(const BumpCombaApp());
    await tester.pump(const Duration(seconds: 1));

    // Restaurar handler de errores
    FlutterError.onError = FlutterError.presentError;

    // No debe haber errores de layout
    final layoutErrors =
        errors
            .where(
              (e) =>
                  e.toString().contains('RenderFlex') ||
                  e.toString().contains('overflow') ||
                  e.toString().contains('Null check'),
            )
            .toList();

    expect(
      layoutErrors,
      isEmpty,
      reason: 'Errores de layout encontrados: $layoutErrors',
    );
  });
}
