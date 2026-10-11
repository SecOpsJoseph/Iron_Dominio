import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

// Paleta: mapa topográfico oscuro + logo en negro, gris y ámbar + papel
const Color _papelClaro = Color(0xFFF1E8D0);
const Color _tinta = Color(0xFF2B2A26);
const Color _verde = Color(0xFF4B5320);
const Color _sello = Color(0xFF8B2E2E);
const Color _ambar = Color(0xFFE0A526);

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _correoCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _cargando = false;
  bool _verPass = false;
  String? _error;

  @override
  void dispose() {
    _correoCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _entrar() async {
    final correo = _correoCtrl.text.trim();
    final pass = _passCtrl.text;

    if (correo.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Escribe tu correo y tu contraseña.');
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: correo,
        password: pass,
      );
      // AuthGate detecta la sesión y cambia de pantalla solo.
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _mensajeError(e.code));
    } catch (_) {
      setState(() => _error = 'Algo salió mal. Intenta de nuevo.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  String _mensajeError(String code) {
    switch (code) {
      case 'invalid-email':
        return 'El correo no tiene un formato válido.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Correo o contraseña incorrectos.';
      case 'user-disabled':
        return 'Esta cuenta está deshabilitada.';
      case 'too-many-requests':
        return 'Demasiados intentos. Espera un momento.';
      case 'network-request-failed':
        return 'Sin conexión a internet.';
      default:
        return 'Error al iniciar sesión ($code).';
    }
  }

  @override
  Widget build(BuildContext context) {
    final borde = OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: const BorderSide(color: _tinta, width: 1.2),
    );

    final tema = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _verde,
        brightness: Brightness.light,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.55),
        border: borde,
        enabledBorder: borde,
        focusedBorder: borde.copyWith(
          borderSide: const BorderSide(color: _verde, width: 2),
        ),
        labelStyle: const TextStyle(
          color: _tinta,
          fontFamily: 'monospace',
          letterSpacing: 1.5,
        ),
        floatingLabelStyle: const TextStyle(
          color: _verde,
          fontFamily: 'monospace',
          letterSpacing: 1.5,
        ),
        prefixIconColor: _tinta,
        suffixIconColor: _tinta,
      ),
    );

    return Theme(
      data: tema,
      child: Scaffold(
        backgroundColor: const Color(0xFF1E211A),
        body: Stack(
          children: [
            // Fondo: mapa topográfico oscurecido
            Positioned.fill(
              child: Image.asset(
                'assets/images/fondo_mapa.jpg',
                fit: BoxFit.cover,
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF14160F).withValues(alpha: 0.80),
                      const Color(0xFF14160F).withValues(alpha: 0.55),
                      const Color(0xFF14160F).withValues(alpha: 0.85),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, c) {
                  final altoLogo = math.max(230.0, c.maxHeight * 0.42);
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _animado(
                            duracion: 800,
                            desde: -24,
                            child: SizedBox(height: altoLogo, child: _portada()),
                          ),
                          _animado(
                            duracion: 900,
                            desde: 60,
                            child: _hojaFormulario(),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Entrada suave: aparece y se desliza en vertical.
  Widget _animado({
    required int duracion,
    required double desde,
    required Widget child,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: duracion),
      curve: Curves.easeOutCubic,
      builder: (_, v, hijo) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, desde * (1 - v)), child: hijo),
      ),
      child: child,
    );
  }

  /// Portada: el logo de Iron Dominio, grande y centrado.
  Widget _portada() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Image.asset(
        'assets/images/icon_foreground.png',
        fit: BoxFit.contain,
        // Si el logo no está en assets, se muestra el nombre en texto.
        errorBuilder: (_, __, ___) => const Center(
          child: Text(
            'IRON DOMINIO',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 36,
              fontWeight: FontWeight.w900,
              letterSpacing: 6,
              color: _ambar,
            ),
          ),
        ),
      ),
    );
  }

  /// Hoja de papel con borde rasgado donde va el formulario.
  Widget _hojaFormulario() {
    return ClipPath(
      clipper: _BordeRasgadoClipper(),
      child: Container(
        color: _papelClaro,
        padding: EdgeInsets.fromLTRB(
          24,
          34,
          24,
          20 + MediaQuery.of(context).padding.bottom,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(width: 4, height: 18, color: _ambar),
                    const SizedBox(width: 8),
                    const Text(
                      'ACCESO AL CUARTEL',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 3,
                        color: _tinta,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _correoCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: _tinta),
                  decoration: const InputDecoration(
                    labelText: 'CORREO',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passCtrl,
                  obscureText: !_verPass,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _entrar(),
                  style: const TextStyle(color: _tinta),
                  decoration: InputDecoration(
                    labelText: 'CONTRASEÑA',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _verPass ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _verPass = !_verPass),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      border: Border.all(color: _sello, width: 1.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _sello,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _cargando ? null : _entrar,
                  style: FilledButton.styleFrom(
                    backgroundColor: _tinta,
                    foregroundColor: _ambar,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: _cargando
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _ambar,
                            ),
                          )
                        : const Text(
                            'ENTRAR AL CAMPO',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'PROTOTIPO · RANGO F',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10,
                    letterSpacing: 2,
                    color: Color(0x992B2A26),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Borde superior en dientes, como papel arrancado.
class _BordeRasgadoClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const diente = 14.0;
    const alto = 7.0;
    final p = Path()..moveTo(0, alto);
    var arriba = true;
    for (double x = 0; x < size.width; x += diente) {
      final xf = math.min(x + diente, size.width);
      p.lineTo(x + diente / 2, arriba ? 0 : alto);
      p.lineTo(xf, alto);
      arriba = !arriba;
    }
    p
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
