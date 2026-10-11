import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'partida_online.dart';

// Paleta: la misma maqueta de papel del login y el menú
const Color _papel = Color(0xFFD8C8A0);
const Color _papelClaro = Color(0xFFF1E8D0);
const Color _tinta = Color(0xFF2B2A26);
const Color _verde = Color(0xFF4B5320);
const Color _sello = Color(0xFF8B2E2E);
const Color _ambar = Color(0xFFE0A526);

/// Busca rival automáticamente. Al encontrarlo hace pop con la [PartidaOnline]
/// (o con null si el jugador cancela); quien la abrió decide qué hacer.
class EmparejamientoPage extends StatefulWidget {
  final String nombre;
  const EmparejamientoPage({super.key, required this.nombre});

  @override
  State<EmparejamientoPage> createState() => _EmparejamientoPageState();
}

class _EmparejamientoPageState extends State<EmparejamientoPage>
    with SingleTickerProviderStateMixin {
  late final Emparejador _emp;
  late final AnimationController _radar;
  Timer? _reloj;
  int _segundos = 0;
  bool _encontrado = false;
  String? _rival;
  String? _fallo;

  @override
  void initState() {
    super.initState();
    _radar = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _reloj = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_encontrado) setState(() => _segundos++);
    });
    _emp = Emparejador(widget.nombre);
    _emp.iniciar();
    _emp.resultado.then(_alResultado);
  }

  @override
  void dispose() {
    _reloj?.cancel();
    _radar.dispose();
    _emp.dispose();
    super.dispose();
  }

  Future<void> _alResultado(String? id) async {
    if (id == null || !mounted) return;
    setState(() => _encontrado = true);
    final partida = await PartidaOnline.cargar(id);
    if (!mounted) return;
    if (partida == null) {
      setState(() {
        _encontrado = false;
        _fallo = 'Se encontró rival pero no pude abrir la partida. '
            'Vuelve al menú y usa CONTINUAR.';
      });
      return;
    }
    setState(() => _rival = partida.nombreRival);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    Navigator.of(context).pop(partida);
  }

  Future<void> _cancelar() async {
    if (_encontrado) return;
    await _emp.cancelar();
    if (mounted) Navigator.of(context).pop();
  }

  String get _tiempo {
    final m = (_segundos ~/ 60).toString().padLeft(2, '0');
    final s = (_segundos % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancelar();
      },
      child: Scaffold(
        backgroundColor: _papel,
        body: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _CuadriculaPainter())),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'OPERACIÓN EN LÍNEA',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            letterSpacing: 3,
                            color: _verde,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _encontrado ? 'OBJETIVO LOCALIZADO' : 'BUSCANDO OPONENTE',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 3,
                            color: _tinta,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Center(
                          child: SizedBox(
                            width: 260,
                            height: 260,
                            child: AnimatedBuilder(
                              animation: _radar,
                              builder: (_, __) => CustomPaint(
                                painter: _RadarPainter(
                                  _radar.value,
                                  encontrado: _encontrado,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: _papelClaro.withValues(alpha: 0.55),
                            border: Border.all(color: _tinta, width: 1.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            children: [
                              _fila('SOLDADO', widget.nombre.toUpperCase()),
                              const SizedBox(height: 6),
                              if (_encontrado && _rival != null)
                                _fila('RIVAL', _rival!.toUpperCase(),
                                    resaltar: true)
                              else
                                _fila('TIEMPO DE BÚSQUEDA', _tiempo),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        ValueListenableBuilder<String?>(
                          valueListenable: _emp.error,
                          builder: (_, e, __) {
                            final texto = _fallo ?? e;
                            if (texto != null) return _aviso(texto);
                            if (_encontrado) {
                              return const Text(
                                'Preparando el tablero...',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  color: _tinta,
                                  letterSpacing: 1,
                                ),
                              );
                            }
                            return Text(
                              _segundos < 45
                                  ? 'Se emparejará con el primer jugador que '
                                      'también esté buscando partida.'
                                  : 'Aún no hay rivales buscando. Si estás '
                                      'probando, pon a buscar también el otro '
                                      'celular.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: Color(0xCC2B2A26),
                                height: 1.4,
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 22),
                        OutlinedButton(
                          onPressed: _encontrado ? null : _cancelar,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _sello,
                            side: const BorderSide(color: _sello, width: 1.6),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              'CANCELAR BÚSQUEDA',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(String etiqueta, String valor, {bool resaltar = false}) {
    return Row(
      children: [
        Text(
          '$etiqueta:',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            letterSpacing: 1.5,
            color: Color(0xAA2B2A26),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            valor,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              color: resaltar ? _sello : _tinta,
            ),
          ),
        ),
      ],
    );
  }

  Widget _aviso(String texto) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: _sello, width: 1.4),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: const TextStyle(color: _sello, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// Radar: anillos, barrido giratorio y un par de "ecos".
class _RadarPainter extends CustomPainter {
  final double t; // 0..1, una vuelta
  final bool encontrado;
  _RadarPainter(this.t, {required this.encontrado});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    final color = encontrado ? _sello : _verde;

    canvas.drawCircle(
      c,
      r,
      Paint()..color = _papelClaro.withValues(alpha: 0.6),
    );

    final linea = Paint()
      ..color = _tinta.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final f in [1.0, 0.75, 0.5, 0.25]) {
      canvas.drawCircle(c, r * f, linea);
    }
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), linea);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), linea);

    final angulo = t * math.pi * 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.5)],
          stops: const [0.7, 1.0],
          transform: GradientRotation(angulo),
        ).createShader(rect),
    );
    canvas.drawLine(
      c,
      Offset(c.dx + r * math.cos(angulo), c.dy + r * math.sin(angulo)),
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );

    // Ecos: aparecen un instante cuando el barrido pasa por encima
    void eco(double ang, double dist) {
      var d = (angulo - ang) % (math.pi * 2);
      if (d < 0) d += math.pi * 2;
      final vida = (1 - d / (math.pi * 1.2)).clamp(0.0, 1.0);
      if (vida <= 0) return;
      canvas.drawCircle(
        Offset(c.dx + r * dist * math.cos(ang), c.dy + r * dist * math.sin(ang)),
        4 + 3 * vida,
        Paint()..color = _ambar.withValues(alpha: vida),
      );
    }

    if (encontrado) {
      canvas.drawCircle(c, 9, Paint()..color = _sello);
      canvas.drawCircle(c, 18, linea..color = _sello);
    } else {
      eco(0.9, 0.62);
      eco(3.6, 0.38);
      eco(5.2, 0.8);
    }

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = _tinta
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(c, 3, Paint()..color = _tinta);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.t != t || old.encontrado != encontrado;
}

/// Fondo tipo tapete de corte / papel cuadriculado (igual que el login).
class _CuadriculaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final fino = Paint()
      ..color = const Color(0x1F2B2A26)
      ..strokeWidth = 1;
    final grueso = Paint()
      ..color = const Color(0x332B2A26)
      ..strokeWidth = 1.2;
    const paso = 24.0;
    int i = 0;
    for (double x = 0; x <= size.width; x += paso, i++) {
      canvas.drawLine(
          Offset(x, 0), Offset(x, size.height), i % 5 == 0 ? grueso : fino);
    }
    i = 0;
    for (double y = 0; y <= size.height; y += paso, i++) {
      canvas.drawLine(
          Offset(0, y), Offset(size.width, y), i % 5 == 0 ? grueso : fino);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
