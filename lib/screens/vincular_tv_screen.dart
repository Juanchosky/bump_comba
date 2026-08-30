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
class VincularTvScreen extends StatefulWidget {
  const VincularTvScreen({super.key});

  @override
  State<VincularTvScreen> createState() => _VincularTvScreenState();
}

class _VincularTvScreenState extends State<VincularTvScreen> {
  final _controlador = TextEditingController();
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
    _cargar();
  }

  @override
  void dispose() {
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
    final codigo = _controlador.text.trim().toUpperCase();
    if (id == null || codigo.replaceAll('-', '').length < 8) return;

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
              ? 'Televisor vinculado. Ya puedes usarlo sin el teléfono.'
              : TvPairingService.explicar(r.motivo, max: r.max);
    });

    if (r.ok) {
      _controlador.clear();
      await _cargar();
    }
  }

  Future<void> _revocar(Map<String, dynamic> tv) async {
    final id = _identidad;
    if (id == null) return;

    final confirmado = await showDialog<bool>(
      context: context,
      builder:
          (c) => AlertDialog(
            backgroundColor: const Color(0xFF1C1C1E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              '¿Quitar este televisor?',
              style: TextStyle(color: Colors.white, fontSize: 17),
            ),
            content: Text(
              'Dejará de mostrar el contenido y tendrás que vincularlo otra '
              'vez si cambias de idea.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text(
                  'Quitar',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirmado != true) return;

    await TvPairingService.instance.revocar(
      userRef: id.ref,
      id: tv['id'].toString(),
    );
    await _cargar();
  }

  // ── Piezas prestadas de la pantalla de configuración ─────────────────────
  Widget _cabecera(String titulo) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 2),
    child: Text(
      titulo.toUpperCase(),
      style: TextStyle(
        color: Colors.red.withValues(alpha: 0.9),
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.4,
      ),
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

  Widget _iconoCuadrado(IconData icono, {Color? color}) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: (color ?? Colors.white).withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(icono, color: color ?? Colors.white54, size: 17),
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
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        children: [
          if (sinSuscripcion) ...[
            _cabecera('Suscripción'),
            const SizedBox(height: 8),
            _tarjeta([
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    _iconoCuadrado(CupertinoIcons.lock_fill, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Necesitas una suscripción activa para ver el '
                        'contenido en el televisor.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
          ] else ...[
            // ── Cómo se hace ────────────────────────────────────────────────
            _cabecera('Cómo se hace'),
            const SizedBox(height: 8),
            _tarjeta([
              _paso(
                1,
                'Abre Bump Comba en el televisor y baja hasta '
                '"Activar este televisor".',
              ),
              _separador(),
              _paso(2, 'Escribe aquí abajo el código que aparece en pantalla.'),
            ]),

            const SizedBox(height: 24),

            // ── El código ───────────────────────────────────────────────────
            _cabecera('Código del televisor'),
            const SizedBox(height: 8),
            _tarjeta([
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                child: Column(
                  children: [
                    TextField(
                      controller: _controlador,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      textAlign: TextAlign.center,
                      cursorColor: Colors.red,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        letterSpacing: 8,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        hintText: 'XXXX-XXXX',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.18),
                          fontSize: 28,
                          letterSpacing: 8,
                          fontWeight: FontWeight.w700,
                        ),
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.04),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: Colors.red,
                            width: 1.5,
                          ),
                        ),
                      ),
                      inputFormatters: [
                        // Se escribe sin pensar en el guion: se pone solo. Y
                        // todo a mayúsculas, como está en el televisor.
                        _FormatoCodigo(),
                      ],
                      onSubmitted: (_) => _vincular(),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _enviando ? null : _vincular,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          disabledBackgroundColor: Colors.red.withValues(
                            alpha: 0.35,
                          ),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child:
                            _enviando
                                ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                                : const Text(
                                  'Vincular',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                      ),
                    ),
                  ],
                ),
              ),
            ]),

            if (_mensaje != null) ...[
              const SizedBox(height: 12),
              _aviso(_mensaje!, _exito),
            ],

            const SizedBox(height: 24),

            // ── Los que ya hay ──────────────────────────────────────────────
            Row(
              children: [
                _cabecera('Televisores vinculados'),
                const Spacer(),
                Text(
                  '${_televisores.length} de $_max',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _tarjeta(
              _cargandoLista
                  ? [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 26),
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
                  ]
                  : _televisores.isEmpty
                  ? [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          _iconoCuadrado(CupertinoIcons.tv),
                          const SizedBox(width: 12),
                          Text(
                            'Todavía no has vinculado ninguno.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ]
                  : [
                    for (int i = 0; i < _televisores.length; i++) ...[
                      if (i > 0) _separador(),
                      _filaTelevisor(_televisores[i]),
                    ],
                  ],
            ),
            const SizedBox(height: 40),
          ],
        ],
      ),
    );
  }

  Widget _paso(int n, String texto) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$n',
            style: const TextStyle(
              color: Colors.red,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              texto,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _filaTelevisor(Map<String, dynamic> tv) {
    final nombre =
        (tv['device_name'] as String?)?.trim().isNotEmpty == true
            ? tv['device_name'] as String
            : 'Televisor';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _iconoCuadrado(CupertinoIcons.tv_fill),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nombre,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _visto(tv['last_seen_at'] as String?),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              CupertinoIcons.xmark_circle_fill,
              color: Colors.white24,
              size: 22,
            ),
            onPressed: () => _revocar(tv),
          ),
        ],
      ),
    );
  }

  Widget _aviso(String texto, bool exito) {
    final color = exito ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            exito
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.exclamationmark_circle_fill,
            size: 19,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texto,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

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

/// Pone el guion solo y fuerza mayúsculas.
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
    final conGuion =
        cortado.length > 4
            ? '${cortado.substring(0, 4)}-${cortado.substring(4)}'
            : cortado;

    return TextEditingValue(
      text: conGuion,
      selection: TextSelection.collapsed(offset: conGuion.length),
    );
  }
}
