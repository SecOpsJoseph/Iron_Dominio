import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'comando.dart';

FirebaseFirestore get _db => FirebaseFirestore.instance;
String get _miUid => FirebaseAuth.instance.currentUser!.uid;

DocumentReference<Map<String, dynamic>> _punteroDe(String uid) =>
    _db.collection('emparejamientos').doc(uid);

DocumentReference<Map<String, dynamic>> _refCola() =>
    _db.collection('matchmaking').doc('cola');

/// Una partida online ya creada. Los dos celulares crean el mismo
/// [EstadoJuego] con la misma semilla y se pasan los comandos por Firestore:
///
///   partidas/{id}                 → jugadores, semilla, estado, ganador, pulsos
///   partidas/{id}/comandos/{n}    → un documento por jugada (n = 00000, 00001...)
class PartidaOnline {
  final String id;

  /// 1 = verde (abajo), 2 = rojo (arriba).
  final int miJugador;
  final int semilla;
  final String nombreRival;

  Timer? _pulso;

  PartidaOnline._({
    required this.id,
    required this.miJugador,
    required this.semilla,
    required this.nombreRival,
  });

  static DocumentReference<Map<String, dynamic>> _ref(String id) =>
      _db.collection('partidas').doc(id);

  /// Abre una partida existente. Devuelve null si no existe o no eres parte.
  static Future<PartidaOnline?> cargar(String id) async {
    try {
      final snap = await _ref(id).get();
      final d = snap.data();
      if (d == null) return null;
      final uid = _miUid;
      final int yo;
      if (d['j1'] == uid) {
        yo = 1;
      } else if (d['j2'] == uid) {
        yo = 2;
      } else {
        return null;
      }
      final rival = (yo == 1 ? d['nombre2'] : d['nombre1']) as String?;
      return PartidaOnline._(
        id: id,
        miJugador: yo,
        semilla: (d['semilla'] as num).toInt(),
        nombreRival: rival ?? 'Rival',
      );
    } catch (_) {
      return null;
    }
  }

  /// Id de la partida activa del usuario (para el botón CONTINUAR), o null.
  static Future<String?> idActiva() async {
    try {
      final ptr = _punteroDe(_miUid);
      final s = await ptr.get();
      final id = s.data()?['partidaId'] as String?;
      if (id == null) return null;
      final p = await _ref(id).get();
      if (p.data()?['estado'] == 'activa') return id;
      await ptr.delete();
    } catch (_) {}
    return null;
  }

  CollectionReference<Map<String, dynamic>> get _comandos =>
      _ref(id).collection('comandos');

  /// Todas las jugadas, en orden. Al entrar de nuevo se repiten desde el inicio.
  Stream<QuerySnapshot<Map<String, dynamic>>> comandos() =>
      _comandos.orderBy('n').snapshots();

  Stream<DocumentSnapshot<Map<String, dynamic>>> partida() =>
      _ref(id).snapshots();

  /// Sube la jugada número [n]. El id del documento es el número, así que dos
  /// jugadas distintas nunca pueden ocupar el mismo lugar.
  Future<void> enviar(int n, Comando c) {
    return _comandos.doc(n.toString().padLeft(5, '0')).set({
      'n': n,
      'jugador': c.jugador,
      'c': c.toJson(),
      'ts': FieldValue.serverTimestamp(),
    });
  }

  /// "Sigo conectado": cada 10 s se escribe un sello de tiempo en la partida.
  void iniciarPulso() {
    _enviarPulso();
    _pulso?.cancel();
    _pulso = Timer.periodic(const Duration(seconds: 10), (_) => _enviarPulso());
  }

  void _enviarPulso() {
    _ref(id)
        .update({'pulso$miJugador': FieldValue.serverTimestamp()})
        .catchError((Object _) {});
  }

  void detener() {
    _pulso?.cancel();
    _pulso = null;
  }

  Future<void> finalizar(int ganador, {String motivo = 'victoria'}) async {
    try {
      await _ref(id).update({
        'estado': 'finalizada',
        'ganador': ganador,
        'motivo': motivo,
      });
    } catch (_) {}
  }

  Future<void> abandonar() =>
      finalizar(miJugador == 1 ? 2 : 1, motivo: 'abandono');

  /// Borra el "puntero" a la partida (ya no aparecerá CONTINUAR).
  Future<void> soltar() async {
    detener();
    try {
      await _punteroDe(_miUid).delete();
    } catch (_) {}
  }
}

/// Emparejamiento automático.
///
/// Hay UN solo documento de cola (matchmaking/cola). Quien busca partida lo lee
/// dentro de una transacción:
///   - si hay alguien esperando (con señal reciente) → crea la partida con él,
///   - si no → se anota él mismo y espera.
/// Mientras espera, repite el intento cada 10 s (así también renueva su señal y
/// se recupera si alguien pisó su lugar). Al emparejarlo, el otro jugador se
/// entera porque se escribe emparejamientos/{su uid} con el id de la partida.
class Emparejador {
  final String nombre;

  /// Mensaje de error de red (null cuando todo va bien).
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);

  Timer? _latido;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  bool _activo = false;
  bool _cerrado = false;
  final Completer<String?> _resultado = Completer<String?>();

  Emparejador(this.nombre);

  /// Completa con el id de la partida, o null si se canceló la búsqueda.
  Future<String?> get resultado => _resultado.future;

  static const Duration _latidoCada = Duration(seconds: 10);
  static const Duration _vencida = Duration(seconds: 35);

  Future<void> iniciar() async {
    _activo = true;
    final ptr = _punteroDe(_miUid);
    try {
      await ptr.delete(); // un puntero viejo no debe contar como emparejamiento
    } catch (_) {}
    if (!_activo) return;
    _sub = ptr.snapshots().listen((s) {
      final id = s.data()?['partidaId'] as String?;
      if (id != null) _terminar(id);
    }, onError: (Object _) {});
    await _intento();
    if (_activo && !_resultado.isCompleted) {
      _latido = Timer.periodic(_latidoCada, (_) => _intento());
    }
  }

  Future<void> _intento() async {
    if (!_activo || _resultado.isCompleted) return;
    final yo = _miUid;
    try {
      final id = await _db.runTransaction<String?>((tx) async {
        final cola = _refCola();
        final s = await tx.get(cola);
        final d = s.data();
        final otro = d?['uid'] as String?;
        final ts = d?['ts'] as Timestamp?;
        final vivo = otro != null &&
            otro != yo &&
            ts != null &&
            DateTime.now().difference(ts.toDate()) < _vencida;

        if (vivo) {
          final azar = math.Random();
          final partida = _db.collection('partidas').doc();
          final yoSoyJ1 = azar.nextBool();
          final nombreOtro = (d?['nombre'] as String?) ?? 'Jugador';
          tx.set(partida, {
            'j1': yoSoyJ1 ? yo : otro,
            'j2': yoSoyJ1 ? otro : yo,
            'nombre1': yoSoyJ1 ? nombre : nombreOtro,
            'nombre2': yoSoyJ1 ? nombreOtro : nombre,
            'semilla': azar.nextInt(1 << 30) + 1,
            'estado': 'activa',
            'ganador': null,
            'creada': FieldValue.serverTimestamp(),
          });
          final aviso = {
            'partidaId': partida.id,
            'ts': FieldValue.serverTimestamp(),
          };
          tx.set(_punteroDe(otro), aviso);
          tx.set(_punteroDe(yo), aviso);
          tx.set(cola, {
            'uid': null,
            'nombre': null,
            'ts': FieldValue.serverTimestamp(),
          });
          return partida.id;
        }

        // Nadie esperando (o el que estaba ya no da señal): me anoto yo.
        tx.set(cola, {
          'uid': yo,
          'nombre': nombre,
          'ts': FieldValue.serverTimestamp(),
        });
        return null;
      });
      if (!_cerrado) error.value = null;
      if (id != null) _terminar(id);
    } catch (_) {
      if (!_cerrado) error.value = 'Sin conexión con el cuartel. Reintentando...';
    }
  }

  void _terminar(String id) {
    if (_resultado.isCompleted) return;
    _detener();
    _resultado.complete(id);
    _liberarCola(); // por si un reintento me anotó justo cuando me emparejaron
  }

  /// Cancela la búsqueda y me saca de la cola.
  Future<void> cancelar() async {
    if (_resultado.isCompleted) return;
    _detener();
    _resultado.complete(null);
    await _liberarCola();
  }

  Future<void> _liberarCola() async {
    try {
      await _db.runTransaction<void>((tx) async {
        final cola = _refCola();
        final s = await tx.get(cola);
        if (s.data()?['uid'] == _miUid) {
          tx.set(cola, {
            'uid': null,
            'nombre': null,
            'ts': FieldValue.serverTimestamp(),
          });
        }
      });
    } catch (_) {}
  }

  void _detener() {
    _activo = false;
    _latido?.cancel();
    _latido = null;
    _sub?.cancel();
    _sub = null;
  }

  void dispose() {
    _cerrado = true;
    if (!_resultado.isCompleted) {
      _detener();
      _resultado.complete(null);
      _liberarCola();
    }
    error.dispose();
  }
}
