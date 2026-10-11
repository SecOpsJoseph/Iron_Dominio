import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'emparejamiento_page.dart';
import 'partida_online.dart';
import 'tablero_page.dart';

// Paleta: maqueta de papel militar sobre un escritorio (igual que el login)
const Color _papel = Color(0xFFD8C8A0);
const Color _papelClaro = Color(0xFFF1E8D0);
const Color _tinta = Color(0xFF2B2A26);
const Color _verde = Color(0xFF4B5320);
const Color _sello = Color(0xFF8B2E2E);
const Color _ambar = Color(0xFFE0A526);

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _nombre = '';
  String? _partidaActiva;
  String? _errorCarga;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final user = FirebaseAuth.instance.currentUser!;
    var nombre = user.email ?? 'Jugador';
    String? error;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .get();
      nombre = (doc.data()?['nombre'] as String?) ?? nombre;
    } catch (e) {
      error = 'No pude leer tu nombre en Firestore.\n$e';
    }
    final activa = await PartidaOnline.idActiva();
    if (!mounted) return;
    setState(() {
      _nombre = nombre;
      _partidaActiva = activa;
      _errorCarga = error;
      _cargando = false;
    });
  }

  Future<void> _buscarPartida() async {
    final partida = await Navigator.of(context).push<PartidaOnline>(
      MaterialPageRoute(builder: (_) => EmparejamientoPage(nombre: _nombre)),
    );
    if (partida != null && mounted) await _abrirPartida(partida);
    if (mounted) _cargar();
  }

  Future<void> _continuar() async {
    final id = _partidaActiva;
    if (id == null) return;
    final partida = await PartidaOnline.cargar(id);
    if (!mounted) return;
    if (partida == null) {
      _cargar();
      return;
    }
    await _abrirPartida(partida);
    if (mounted) _cargar();
  }

  Future<void> _abrirPartida(PartidaOnline p) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TableroPage(online: p)),
    );
  }

  void _practica() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TableroPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final idCorto = user.uid.length >= 6
        ? user.uid.substring(0, 6).toUpperCase()
        : user.uid.toUpperCase();

    return Scaffold(
      backgroundColor: _papel,
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _CuadriculaPainter())),
          SafeArea(
            child: Center(
              child: _cargando
                  ? const CircularProgressIndicator(color: _verde)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(18),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: _hoja(user.email ?? '', idCorto),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// La hoja de servicio: papel claro con agujeros de carpeta, sello y casillas.
  Widget _hoja(String correo, String idCorto) {
    return Container(
      decoration: BoxDecoration(
        color: _papelClaro,
        border: Border.all(color: _tinta, width: 1.4),
        borderRadius: BorderRadius.circular(3),
        boxShadow: const [
          BoxShadow(color: Color(0x552B2A26), blurRadius: 10, offset: Offset(3, 5)),
        ],
      ),
      child: Stack(
        children: [
          // Agujeros de carpeta
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (var i = 0; i < 3; i++)
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _papel,
                      shape: BoxShape.circle,
                      border: Border.all(color: _tinta.withValues(alpha: 0.5)),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _encabezado(),
                const SizedBox(height: 14),
                const _Separador(),
                const SizedBox(height: 12),
                _campo('SOLDADO', _nombre.toUpperCase()),
                _campo('RANGO', 'F · RECLUTA'),
                _campo('IDENTIFICACIÓN', idCorto),
                _campo('CORREO', correo),
                _campo('ESTADO', 'EN SERVICIO'),
                if (_errorCarga != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorCarga!,
                    style: const TextStyle(color: _sello, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 14),
                const _Separador(),
                const SizedBox(height: 12),
                const Text(
                  'ÓRDENES DISPONIBLES',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 3,
                    color: _verde,
                  ),
                ),
                const SizedBox(height: 10),
                if (_partidaActiva != null) ...[
                  _orden(
                    marca: '▶',
                    titulo: 'CONTINUAR OPERACIÓN',
                    detalle: 'Tienes una partida en curso',
                    color: _ambar,
                    textoColor: _tinta,
                    onTap: _continuar,
                  ),
                  const SizedBox(height: 10),
                ] else ...[
                  _orden(
                    marca: 'I',
                    titulo: 'OPERACIÓN EN LÍNEA',
                    detalle: 'Buscar partida · emparejamiento automático',
                    color: _verde,
                    textoColor: _papelClaro,
                    onTap: _buscarPartida,
                  ),
                  const SizedBox(height: 10),
                ],
                _orden(
                  marca: 'II',
                  titulo: 'PRÁCTICA',
                  detalle: 'Los dos jugadores en este celular',
                  color: Colors.transparent,
                  textoColor: _tinta,
                  borde: true,
                  onTap: _practica,
                ),
                const SizedBox(height: 18),
                const _Separador(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'FIRMA DEL COMANDANTE',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10,
                          letterSpacing: 1.5,
                          color: Color(0x992B2A26),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      icon: const Icon(Icons.logout, size: 16),
                      label: const Text(
                        'CERRAR SESIÓN',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          letterSpacing: 1,
                        ),
                      ),
                      style: TextButton.styleFrom(foregroundColor: _sello),
                    ),
                  ],
                ),
                Text(
                  _nombre,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontStyle: FontStyle.italic,
                    fontSize: 18,
                    color: Color(0xFF1F3A6E),
                  ),
                ),
                const SizedBox(height: 2),
                const _Separador(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _encabezado() {
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'FORMULARIO ID-01',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                letterSpacing: 2,
                color: Color(0x992B2A26),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'IRON\nDOMINIO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 30,
                height: 1.05,
                fontWeight: FontWeight.w900,
                letterSpacing: 5,
                color: _tinta,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'HOJA DE SERVICIO',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                letterSpacing: 3,
                color: _verde,
              ),
            ),
          ],
        ),
        Positioned(
          right: 0,
          top: 14,
          child: Transform.rotate(
            angle: -0.2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: _sello.withValues(alpha: 0.85), width: 2.5),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                'CONFIDENCIAL',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                  color: _sello.withValues(alpha: 0.85),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _campo(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '$etiqueta:',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 1.5,
              color: Color(0xAA2B2A26),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(bottom: 1),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Color(0x662B2A26), width: 1),
                ),
              ),
              child: Text(
                valor,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                  color: _tinta,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Una orden: casilla con número romano + título + detalle.
  Widget _orden({
    required String marca,
    required String titulo,
    required String detalle,
    required Color color,
    required Color textoColor,
    required VoidCallback onTap,
    bool borde = false,
  }) {
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: _tinta, width: borde ? 1.4 : 1.2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(color: textoColor, width: 1.5),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  marca,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w900,
                    color: textoColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: textoColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detalle,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: textoColor.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: textoColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// Línea punteada tipo formulario.
class _Separador extends StatelessWidget {
  const _Separador();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      width: double.infinity,
      child: CustomPaint(painter: _PunteadoPainter()),
    );
  }
}

class _PunteadoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x882B2A26)
      ..strokeWidth = 1.2;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, 0), Offset(x + 4, 0), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
