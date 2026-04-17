import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DisclaimerDialog extends StatefulWidget {
  final VoidCallback onAccept;

  const DisclaimerDialog({super.key, required this.onAccept});

  @override
  State<DisclaimerDialog> createState() => _DisclaimerDialogState();
}

class _DisclaimerDialogState extends State<DisclaimerDialog> {
  bool _canAccept = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (_scrollController.offset >=
          _scrollController.position.maxScrollExtent - 50) {
        if (!_canAccept && mounted) {
          setState(() {
            _canAccept = true;
          });
        }
      }
    });
  }

  // Allow accept immediately for short text, but listening to scroll is safer for long legal text
  // For this version where text is short, we enable it by default or after short delay
  // But to be "serious", let's enable it after 2 seconds

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _canAccept = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // Force user to interact
      child: AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.gavel, color: Colors.white70),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Aviso Legal',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          height: 300,
          width: double.maxFinite,
          child: Column(
            children: [
              Expanded(
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: const Text(
                      '''

Esta aplicación es una plataforma de entretenimiento que combina juegos interactivos con un Lector de Listas Multimedia (M3U).

1. NATURALEZA MIXTA: Disfruta de nuestros juegos y mecánicas interactivas. La función de reproductor es una herramienta adicional para tu contenido personal.

2. SIN CONTENIDO INCLUIDO: La aplicación NO incluye, aloja ni vende ningún contenido de video. Actúa exclusivamente como un reproductor para el contenido que TÚ nos proporciones.

3. RESPONSABILIDAD: El usuario es el único responsable del contenido que decide reproducir. Los desarrolladores no tienen relación con las listas o transmisiones externas.

Al presionar "Acepto", entiendes la naturaleza de la aplicación y aceptas usar sus herramientas de reproducción bajo tu propia responsabilidad.
                       ''',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () {
              // Exit app if rejected (simulated with minimize or strict pop)
              // For now just pop usually means "I assume you exit".
              // SystemNavigator.pop() is discouraged on iOS but works on Android.
              // We'll just show a snackbar saying "Required".
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Debes aceptar para usar la aplicación.'),
                ),
              );
            },
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white54),
            child: const Text('Salir'),
          ),
          ElevatedButton(
            onPressed:
                _canAccept
                    ? () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('disclaimer_accepted', true);
                      widget.onAccept();
                    }
                    : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _canAccept ? Colors.red : Colors.grey[800],
              foregroundColor: Colors.white,
            ),
            child: Text(_canAccept ? 'Acepto y Entiendo' : 'Lee todo...'),
          ),
        ],
      ),
    );
  }
}
