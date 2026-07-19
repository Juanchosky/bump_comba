import 'package:flutter/material.dart';

import '../../utils/colors.dart';
import 'tv_receiver_screen.dart';

/// App raíz cuando Bump Comba corre en un TV. SOLO monta la pantalla
/// receptora — sin anuncios, notificaciones ni el resto de servicios del
/// teléfono.
class TvReceiverApp extends StatelessWidget {
  const TvReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bump Comba TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.dark,
          surface: Colors.black,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const TvReceiverScreen(),
    );
  }
}
