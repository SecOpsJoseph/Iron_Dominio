import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'comando.dart';
import 'juego_estado.dart';
import 'obstaculo_modelo.dart';
import 'partida_online.dart';
import 'tanque.dart';

// Qué tan grande es el mapa respecto al ancho de la pantalla.
// Más alto = casillas más grandes (y más espacio para recorrer).
const double ampliacion = 4.0;
const double ampliacionEsteOeste = 4.0;

// Zoom máximo con pellizco.
const double zoomMaximo = 3.5;
const double zoomMaximoEsteOeste = 2.5;

const double zoomMinimoEsteOeste = 0.35;
const double zoomMinimoNorteSur = 0.35;

// Medidas de la imagen del papel (papel_tablero.png).
const double _papelAncho = 1070;
const double _papelAlto = 1470;

const Color _tinta = Color(0xFF2B2A26);
const Color _verde = Color(0xFF4B5320);
const Color _ambar = Color(0xFFE0A526);
const Color _sello = Color(0xFF8B2E2E);
const Color _rojo = Color(0xFFC1432D);
const Color _papelClaro = Color(0xFFF1E8D0);
const Color _fondoTablero = Color(0xFF505448);
const Color _fondoBarra = Color(0xCC383D32);
const Color _azulZona = Color(0xFF2F9BE8);
const Color _fuego = Color(0xFFE8731A);
const Color _bengala = Color(0xFFF2D13C);
const Color _sanitario = Color(0xFF3FA66B);

enum _Modo {
  mover,
  atacar,
  perforante,
  escape,
  rafaga,
  embestida,
  sacrificio,
  sacos,
  rompemuros,
  operacion,
  bengala,
  incendiaria,
  bombardeo,
  mina,
  lapa,
  campo,
  reparacion,
  cable, // paso 1: elegir aliado
  cableDestino, // paso 2: elegir casilla
  estacion,
}

class TableroPage extends StatefulWidget {
  /// null = práctica (los dos jugadores en este celular).
  final PartidaOnline? online;

  const TableroPage({super.key, this.online});

  @override
  State<TableroPage> createState() => _TableroPageState();
}

class _TableroPageState extends State<TableroPage>
    with SingleTickerProviderStateMixin {
  final TransformationController _ctrl = TransformationController();
  late final AnimationController _reboteCtrl;
  Size _tamanoViewport = Size.zero;
  bool _llegoAlMinimoAlejando = false;
  double _escalaInicioInteraccion = 1;
  double _escalaElasticActual = 1;
  double _escalaElasticInicial = 1;
  Matrix4 _baseRebote = Matrix4.identity();

  // false = norte contra sur (bases arriba y abajo)
  // true  = este contra oeste (bases a los lados)
  bool _esteOeste = false;
  bool _centrar = true;

  // ---- Partida (práctica en un celular, u online contra otro jugador) ----
  late final EstadoJuego _juego;
  ClaseTanque? _claseElegida;
  int? _selId;
  _Modo _modo = _Modo.mover;
  Set<int> _alcanzables = {};
  RangoAtaque? _rango;
  String _info = '';
  final List<int> _marcadas = []; // casillas elegidas para construir muros
  int? _cableId; // aliado elegido para el Cable de Remolque
  bool _cableJalar = true; // true: jalar al aliado · false: ir hacia él

  // ---- Online ----
  PartidaOnline? get _online => widget.online;
  int? get _yo => widget.online?.miJugador;
  bool get _esMiTurno => _online == null || _juego.jugador == _yo;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subComandos;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _subPartida;
  Timer? _relojPresencia;
  DateTime _rivalVisto = DateTime.now();
  Object? _ultimoPulsoRival;
  bool _errorEnvio = false;
  bool _desincronizado = false;
  bool _finMostrado = false;
  String? _motivoFin;

  double get _zoomMinimoOrientacion =>
      _esteOeste ? zoomMinimoEsteOeste : zoomMinimoNorteSur;
  double get _zoomMaximoOrientacion =>
      _esteOeste ? zoomMaximoEsteOeste : zoomMaximo;

  @override
  void initState() {
    super.initState();
    _reboteCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addListener(_actualizarRebote);

    final online = widget.online;
    _juego = online == null
        ? EstadoJuego()
        : EstadoJuego(semilla: online.semilla);
    if (online != null) {
      _subComandos = online.comandos().listen(
        _alLlegarComandos,
        onError: (Object _) {
          if (mounted) setState(() => _errorEnvio = true);
        },
      );
      _subPartida = online.partida().listen(_alCambiarPartida);
      online.iniciarPulso();
      // Refresca el aviso de "rival sin señal" aunque no llegue nada nuevo.
      _relojPresencia = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _subComandos?.cancel();
    _subPartida?.cancel();
    _relojPresencia?.cancel();
    widget.online?.detener();
    _reboteCtrl.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ---------------- Zoom elástico (tu versión) ----------------

  void _actualizarRebote() {
    final progreso = Curves.easeInOutSine.transform(_reboteCtrl.value);
    final escala = _escalaElasticInicial +
        (1 - _escalaElasticInicial) * progreso;
    _aplicarEscalaDesdeCentro(_baseRebote, escala);
  }

  void _aplicarEscalaDesdeCentro(Matrix4 matriz, double escala) {
    if (_tamanoViewport.isEmpty) return;
    final centro = _tamanoViewport.center(Offset.zero);
    final rebote = Matrix4.translationValues(centro.dx, centro.dy, 0)
      ..scale(escala)
      ..translate(-centro.dx, -centro.dy);
    _ctrl.value = rebote * matriz;
  }

  void _alIniciarInteraccion(ScaleStartDetails details) {
    if (_reboteCtrl.isAnimating) {
      _reboteCtrl.stop();
      _aplicarEscalaDesdeCentro(_baseRebote, 1);
    }
    _escalaInicioInteraccion = _ctrl.value.getMaxScaleOnAxis();
    _llegoAlMinimoAlejando = false;
  }

  void _actualizarInteraccion(ScaleUpdateDetails details) {
    final escalaSolicitada = _escalaInicioInteraccion * details.scale;
    if (escalaSolicitada >= _zoomMinimoOrientacion) {
      _llegoAlMinimoAlejando = false;
      _escalaElasticActual = 1;
      return;
    }

    final exceso =
        (_zoomMinimoOrientacion - escalaSolicitada) / _zoomMinimoOrientacion;
    _escalaElasticActual = 1 - 0.035 * exceso / (exceso + 0.12);
    _escalaElasticInicial = _escalaElasticActual;
    _baseRebote = _ctrl.value.clone();
    _llegoAlMinimoAlejando = true;
    _aplicarEscalaDesdeCentro(_baseRebote, _escalaElasticActual);
  }

  void _alTerminarInteraccion(ScaleEndDetails details) {
    if (_llegoAlMinimoAlejando) {
      _escalaElasticInicial = _escalaElasticActual;
      _reboteCtrl.forward(from: 0);
    }
    _llegoAlMinimoAlejando = false;
  }

  void _alternarOrientacion() {
    _reboteCtrl.stop();
    _llegoAlMinimoAlejando = false;
    _escalaElasticActual = 1;
    _escalaElasticInicial = 1;
    setState(() {
      _esteOeste = !_esteOeste;
      _centrar = true;
    });
  }

  // ---------------- Interacción con la partida ----------------

  /// Todas las acciones de la partida pasan por aquí: se arma un Comando y se
  /// aplica con [EstadoJuego.aplicar]. Devuelve el texto del resultado, o null
  /// si la acción no era válida. En modo online, este mismo comando se enviará
  /// al servidor en vez de aplicarse aquí.
  String? _jugar(
    TipoComando tipo, {
    Tanque? tanque,
    int? col,
    int? fila,
    String? clase,
    int? aliado,
    bool? jalar,
    List<int>? celdas,
  }) {
    final online = _online;
    // Online: solo se juega en tu turno y sin que la partida esté desincronizada.
    if (online != null && (!_esMiTurno || _desincronizado)) return null;
    final cmd = Comando(
      tipo: tipo,
      jugador: _juego.jugador,
      tanqueId: tanque?.id,
      col: col,
      fila: fila,
      clase: clase,
      aliadoId: aliado,
      jalar: jalar,
      celdas: celdas,
    );
    final r = _juego.aplicar(cmd);
    if (!r.ok) return null;
    if (online != null) {
      // Se aplica aquí al instante y se envía al rival.
      online.enviar(_juego.historial.length - 1, cmd).catchError((Object _) {
        if (mounted) setState(() => _errorEnvio = true);
      });
      if (_juego.ganador != null) online.finalizar(_juego.ganador!);
    }
    return r.texto;
  }

  // ---------------- Online: llegada de jugadas del rival ----------------

  /// Aplica, en orden, las jugadas que todavía no están en este celular.
  /// Las propias ya se aplicaron al jugarlas, así que se saltan solas.
  void _alLlegarComandos(QuerySnapshot<Map<String, dynamic>> snap) {
    if (_desincronizado || !mounted) return;
    final eraMiTurno = _esMiTurno;
    var aplicados = 0;
    var delRival = '';
    var delTurno = '';
    for (final d in snap.docs) {
      final datos = d.data();
      final n = (datos['n'] as num).toInt();
      if (n != _juego.historial.length) continue;
      try {
        final c = Comando.fromJson(Map<String, dynamic>.from(datos['c'] as Map));
        final r = _juego.aplicar(c);
        if (!r.ok) {
          // Si la partida ya se cerró por abandono/desconexión no es un error.
          if (_juego.ganador == null) _desincronizado = true;
          break;
        }
        aplicados++;
        if (c.tipo == TipoComando.terminarTurno) {
          delTurno = r.texto;
        } else if (c.jugador != _yo &&
            c.tipo != TipoComando.mina && // las minas son ocultas
            r.texto.isNotEmpty) {
          delRival = r.texto;
        }
      } catch (_) {
        _desincronizado = true;
        break;
      }
    }
    if (aplicados == 0 && !_desincronizado) return;
    setState(() {
      if (aplicados > 0) {
        _limpiarSeleccion();
        _info = [
          if (delRival.isNotEmpty) 'Rival: $delRival',
          if (delTurno.isNotEmpty) delTurno,
        ].join('\n');
      }
    });
    if (!eraMiTurno && _esMiTurno && _juego.ganador == null) {
      HapticFeedback.mediumImpact();
    }
  }

  void _alCambiarPartida(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data();
    if (d == null || !mounted) return;
    final rival = _yo == 1 ? 2 : 1;
    final pulso = d['pulso$rival'];
    if (pulso != null && pulso != _ultimoPulsoRival) {
      _ultimoPulsoRival = pulso;
      _rivalVisto = DateTime.now();
    }
    final g = d['ganador'];
    final motivo = d['motivo'] as String?;
    // Una victoria normal llega sola con la última jugada; aquí solo se
    // atienden los cierres por abandono o desconexión.
    if (d['estado'] == 'finalizada' &&
        g is int &&
        _juego.ganador == null &&
        motivo != 'victoria') {
      _motivoFin = motivo;
      setState(() => _juego.ganador = g);
    } else {
      setState(() {});
    }
  }

  Future<void> _reclamarVictoria() async {
    final online = _online;
    if (online == null) return;
    await online.finalizar(online.miJugador, motivo: 'desconexion');
  }

  Future<void> _salirDePartida() async {
    await _online?.soltar();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pedirSalida() async {
    final online = _online;
    if (online == null) return;
    if (_juego.ganador != null) {
      await _salirDePartida();
      return;
    }
    final r = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Dejar la operación?'),
        content: const Text(
          'SALIR: la partida sigue activa y puedes volver desde el menú '
          '(CONTINUAR OPERACIÓN).\n\nABANDONAR: das la partida por perdida.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'seguir'),
            child: const Text('SEGUIR'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'salir'),
            child: const Text('SALIR'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'abandonar'),
            child: const Text('ABANDONAR', style: TextStyle(color: _rojo)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (r == 'salir') {
      Navigator.of(context).pop();
    } else if (r == 'abandonar') {
      await online.abandonar();
      await _salirDePartida();
    }
  }

  Future<void> _mostrarFin() async {
    if (!mounted) return;
    final gane = _juego.ganador == _yo;
    final detalle = switch (_motivoFin) {
      'abandono' => gane ? 'El rival abandonó la partida.' : 'Abandonaste la partida.',
      'desconexion' => gane
          ? 'El rival perdió la conexión.'
          : 'Perdiste la conexión demasiado tiempo.',
      _ => gane ? 'Destruiste todos los tanques enemigos.' : 'Perdiste todos tus tanques.',
    };
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(gane ? '¡VICTORIA!' : 'DERROTA'),
        content: Text(detalle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('VOLVER AL CUARTEL'),
          ),
        ],
      ),
    );
    await _salirDePartida();
  }

  /// Avisos de conexión que se muestran encima de los botones.
  List<Widget> _avisosOnline() {
    final online = _online;
    if (online == null) return const [];
    Widget caja(String texto, {Widget? accion}) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: _ambar),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            children: [
              Text(
                texto,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _ambar, fontSize: 12),
              ),
              if (accion != null) accion,
            ],
          ),
        );
    final avisos = <Widget>[];
    if (_desincronizado) {
      avisos.add(caja('La partida se desincronizó. Sal al menú y entra con '
          'CONTINUAR OPERACIÓN.'));
    } else if (_errorEnvio) {
      avisos.add(caja('El servidor rechazó una jugada. Si el tablero se ve '
          'raro, sal y vuelve a entrar.'));
    }
    final sinSenal = DateTime.now().difference(_rivalVisto).inSeconds;
    if (_juego.ganador == null && sinSenal > 45) {
      avisos.add(caja(
        '${online.nombreRival} sin señal hace ${sinSenal}s',
        accion: sinSenal > 90
            ? TextButton(
                onPressed: _reclamarVictoria,
                child: const Text('RECLAMAR VICTORIA'),
              )
            : null,
      ));
    }
    return avisos;
  }

  Tanque? get _seleccionado {
    if (_selId == null) return null;
    for (final t in _juego.tanques) {
      if (t.id == _selId) return t;
    }
    return null;
  }

  void _limpiarSeleccion() {
    _selId = null;
    _alcanzables = {};
    _rango = null;
    _info = '';
    _marcadas.clear();
    _cableId = null;
  }

  void _seleccionar(Tanque t) {
    _selId = t.id;
    _modo = !_juego.puedeMover(t) ||
            _juego.movidos.contains(t.id) ||
            _juego.dispararon.contains(t.id)
        ? _Modo.atacar
        : _Modo.mover;
    _info = '';
    _cableId = null;
    _recalcular();
  }

  Tanque? _tanquePorId(int id) {
    for (final t in _juego.tanques) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _recalcular() {
    final sel = _seleccionado;
    if (sel == null) return;
    if (_modo != _Modo.sacos &&
        _modo != _Modo.operacion &&
        _modo != _Modo.bombardeo &&
        _modo != _Modo.campo) {
      _marcadas.clear();
    }
    final yaDisparo = !_juego.puedeDisparar(sel);
    if (_modo == _Modo.mover) {
      _alcanzables = _juego.alcanzables(sel);
    } else if (_modo == _Modo.rafaga) {
      _alcanzables = _juego.destinosRafaga(sel);
    } else if (_modo == _Modo.embestida) {
      _alcanzables = _juego.objetivosEmbestida(sel);
    } else if (_modo == _Modo.sacos) {
      _alcanzables = _juego.casillasSacos(sel);
    } else if (_modo == _Modo.operacion) {
      _alcanzables = _juego.casillasOperacion(sel);
    } else if (_modo == _Modo.rompemuros) {
      _alcanzables = _juego.objetivosRompemuros(sel);
    } else if (_modo == _Modo.bengala) {
      _alcanzables = _juego.casillasBengala(sel);
    } else if (_modo == _Modo.incendiaria) {
      _alcanzables = _juego.casillasIncendiaria(sel);
    } else if (_modo == _Modo.bombardeo) {
      _alcanzables = _juego.casillasBombardeo(sel);
    } else if (_modo == _Modo.mina) {
      _alcanzables = _juego.casillasMina(sel);
    } else if (_modo == _Modo.lapa) {
      _alcanzables = _juego.objetivosLapa(sel);
    } else if (_modo == _Modo.campo) {
      _alcanzables = _juego.casillasCampo(sel);
    } else if (_modo == _Modo.reparacion) {
      _alcanzables = _juego.objetivosReparacion(sel);
    } else if (_modo == _Modo.cable) {
      _alcanzables = _juego.objetivosCable(sel);
    } else if (_modo == _Modo.cableDestino) {
      final aliado = _cableId == null ? null : _tanquePorId(_cableId!);
      _alcanzables = aliado == null
          ? {}
          : _juego.destinosCable(sel, aliado, _cableJalar);
    } else {
      _alcanzables = {};
    }
    _rango = (_modo == _Modo.atacar ||
                _modo == _Modo.perforante ||
                _modo == _Modo.escape ||
                _modo == _Modo.sacrificio ||
                _modo == _Modo.incendiaria ||
                _modo == _Modo.lapa) &&
            !yaDisparo
        ? _juego.rangoDe(sel)
        : null;
    if (_info.isEmpty) {
      if (_modo == _Modo.mover && !_juego.puedeMover(sel)) {
        _info = _juego.trincherados.contains(sel.id)
            ? 'Atrincherado: no puede moverse'
            : _juego.estaAtascado(sel)
                ? 'Atascado: no puede moverse hasta que termine el turno'
                : 'Sin Fichas de Acción para moverse';
      } else if (_modo != _Modo.mover && yaDisparo) {
        _info = 'Sin Fichas de Acción para atacar';
      } else if (_modo == _Modo.reparacion && _alcanzables.isEmpty) {
        _info = 'No hay aliados adyacentes para reparar';
      } else if (_modo == _Modo.cable && _alcanzables.isEmpty) {
        _info = 'No hay aliados a rango ${EstadoJuego.rangoCable} con visión';
      } else if (_modo == _Modo.cableDestino && _alcanzables.isEmpty) {
        _info = 'No hay casillas libres para esa opción';
      } else if (_modo == _Modo.mina && _alcanzables.isEmpty) {
        _info = _juego.minasPresionDe(sel.jugador) >=
                EstadoJuego.maxMinasPresion
            ? 'Ya tienes ${EstadoJuego.maxMinasPresion} minas activas'
            : 'No hay casillas libres para una mina';
      }
    }
  }

  String _describirObjetivo(int col, int fila) {
    final t = _juego.tanqueEn(col, fila);
    if (t != null) {
      return 'Objetivo: ${t.clase.nombre} enemigo · HP ${t.vida}/${t.clase.vida}'
          ' · Armor ${t.armor}/${t.armorMaximo}';
    }
    final o = _juego.obstaculoEn(col, fila);
    if (o != null) {
      return 'Objetivo: ${o.tipo.nombre} · HP ${o.hp}/${Obstaculo.hpMuro}';
    }
    return '';
  }

  void _alTocar(int col, int fila) {
    if (!_esMiTurno) return; // online: en el turno del rival solo se mira
    final t = _juego.tanqueEn(col, fila);

    if (_juego.fase == Fase.despliegue) {
      // Tocar un tanque propio lo quita
      if (t != null && t.jugador == _juego.jugador) {
        setState(() => _jugar(TipoComando.quitar, col: col, fila: fila));
        return;
      }
      if (t != null || _claseElegida == null) return;
      setState(() => _jugar(TipoComando.colocar,
          clase: _claseElegida!.clave, col: col, fila: fila));
      return;
    }

    // Fase de juego
    if (_juego.ganador != null) return;
    final sel = _seleccionado;
    final k = EstadoJuego.idx(col, fila);

    // Maniobra de Escape: después de disparar, mover 1 casilla (o cancelar tocando otra cosa)
    final pend = _juego.escapePendiente;
    if (pend != null) {
      final tp = _tanquePorId(pend);
      if (tp != null && _juego.casillasEscape(tp).contains(k)) {
        setState(() {
          _info = _jugar(TipoComando.completarEscape,
                  tanque: tp, col: col, fila: fila) ??
              '';
          _selId = tp.id;
          _modo = _Modo.atacar;
          _recalcular();
        });
        return;
      }
      _juego.escapePendiente = null;
    }

    if (sel != null && _modo == _Modo.embestida && _alcanzables.contains(k)) {
      setState(() {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoEmbestida)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoEmbestida} EN)';
          return;
        }
        _info = _jugar(TipoComando.embestida, tanque: sel, col: col, fila: fila) ??
            '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    if (sel != null && _modo == _Modo.rafaga && _alcanzables.contains(k)) {
      setState(() {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoRafaga)) {
          _info = 'Energía insuficiente (cuesta ${EstadoJuego.costoRafaga} EN)';
          return;
        }
        _info = _jugar(TipoComando.rafaga, tanque: sel, col: col, fila: fila) ?? '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    // Artillero: Bengala y Munición Incendiaria se disparan al tocar la casilla
    if (sel != null &&
        (_modo == _Modo.bengala || _modo == _Modo.incendiaria) &&
        _alcanzables.contains(k)) {
      final esBengala = _modo == _Modo.bengala;
      final costo =
          esBengala ? EstadoJuego.costoBengala : EstadoJuego.costoIncendiaria;
      setState(() {
        if (!_juego.puedePagarDisparo(sel, costo)) {
          _info = 'Energía insuficiente (cuesta $costo EN)';
          return;
        }
        _info = (esBengala
                ? _jugar(TipoComando.bengala, tanque: sel, col: col, fila: fila)
                : _jugar(TipoComando.incendiaria,
                    tanque: sel, col: col, fila: fila)) ??
            '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    // Bombardeo de Precisión y Campo Minado: se marca la zona (vista previa)
    // y se confirma con el botón
    if (sel != null &&
        (_modo == _Modo.bombardeo || _modo == _Modo.campo) &&
        _alcanzables.contains(k)) {
      setState(() {
        _marcadas
          ..clear()
          ..add(k);
        _info = 'Zona marcada: toca Confirmar (o toca otra casilla para moverla)';
      });
      return;
    }

    // Sembrador: Mina de Presión y Carga Lapa se usan al tocar la casilla
    if (sel != null &&
        (_modo == _Modo.mina || _modo == _Modo.lapa) &&
        _alcanzables.contains(k)) {
      final esMina = _modo == _Modo.mina;
      final costo = esMina ? EstadoJuego.costoMina : EstadoJuego.costoLapa;
      setState(() {
        if (!_juego.puedePagarDisparo(sel, costo)) {
          _info = 'Energía insuficiente (cuesta $costo EN)';
          return;
        }
        _info = (esMina
                ? _jugar(TipoComando.mina, tanque: sel, col: col, fila: fila)
                : _jugar(TipoComando.lapa, tanque: sel, col: col, fila: fila)) ??
            '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    // Soporte: Reparación (toca al aliado adyacente)
    if (sel != null && _modo == _Modo.reparacion && _alcanzables.contains(k)) {
      setState(() {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoReparacion)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoReparacion} EN)';
          return;
        }
        _info = _jugar(TipoComando.reparar, tanque: sel, col: col, fila: fila) ??
            '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    // Soporte: Cable de Remolque, paso 1 (elegir aliado)
    if (sel != null && _modo == _Modo.cable && _alcanzables.contains(k)) {
      setState(() {
        final aliado = _juego.tanqueEn(col, fila);
        if (aliado == null) return;
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoCable)) {
          _info = 'Energía insuficiente (cuesta ${EstadoJuego.costoCable} EN)';
          return;
        }
        _cableId = aliado.id;
        _cableJalar = true;
        _modo = _Modo.cableDestino;
        _info = 'Elige la casilla (o cambia entre Jalar / Ir hacia él)';
        _recalcular();
      });
      return;
    }

    // Soporte: Cable de Remolque, paso 2 (elegir casilla)
    if (sel != null &&
        _modo == _Modo.cableDestino &&
        _alcanzables.contains(k)) {
      final aliado = _cableId == null ? null : _tanquePorId(_cableId!);
      setState(() {
        _info = aliado == null
            ? ''
            : _jugar(TipoComando.cable,
                    tanque: sel,
                    aliado: aliado.id,
                    jalar: _cableJalar,
                    col: col,
                    fila: fila) ??
                '';
        _cableId = null;
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    // Muros del Zapador: se marcan las casillas (se pueden cambiar) y se confirma con el botón
    if (sel != null &&
        (_modo == _Modo.sacos || _modo == _Modo.operacion) &&
        _alcanzables.contains(k)) {
      final necesarias = _modo == _Modo.sacos ? 1 : 2;
      setState(() {
        if (_marcadas.contains(k)) {
          _marcadas.remove(k);
        } else {
          if (_marcadas.length >= necesarias) _marcadas.removeAt(0);
          _marcadas.add(k);
        }
        _info = _marcadas.length == necesarias
            ? 'Casillas marcadas: toca Confirmar (o toca otra para cambiarla)'
            : 'Marca $necesarias casilla(s) libre(s) (${_marcadas.length}/$necesarias)';
      });
      return;
    }

    if (sel != null && _modo == _Modo.rompemuros && _alcanzables.contains(k)) {
      setState(() {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoRompemuros)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoRompemuros} EN)';
          return;
        }
        _info = _jugar(TipoComando.rompemuros,
                tanque: sel, col: col, fila: fila) ??
            '';
        _modo = _Modo.atacar;
        _recalcular();
      });
      return;
    }

    if (sel != null && _modo == _Modo.mover && _alcanzables.contains(k)) {
      setState(() {
        final aviso =
            _jugar(TipoComando.mover, tanque: sel, col: col, fila: fila);
        _limpiarSeleccion();
        _info = aviso ?? '';
      });
      return;
    }

    if (sel != null &&
        (_modo == _Modo.atacar ||
            _modo == _Modo.perforante ||
            _modo == _Modo.escape ||
            _modo == _Modo.sacrificio) &&
        _rango != null &&
        _rango!.objetivos.contains(k)) {
      final esEscape = _modo == _Modo.escape;
      final esPerforante = _modo == _Modo.perforante;
      final esSacrificio = _modo == _Modo.sacrificio;
      final costo = esEscape
          ? EstadoJuego.costoEscape
          : esPerforante
              ? EstadoJuego.costoPerforante
              : esSacrificio
                  ? EstadoJuego.costoSacrificio
                  : sel.clase.costoTiro;
      setState(() {
        if (!_juego.puedePagarDisparo(sel, costo)) {
          _info = 'Energía insuficiente (cuesta $costo EN)';
          return;
        }
        final tipo = esSacrificio
            ? TipoComando.sacrificio
            : esEscape
                ? TipoComando.escape
                : esPerforante
                    ? TipoComando.perforante
                    : TipoComando.disparar;
        final resultado = _jugar(tipo, tanque: sel, col: col, fila: fila);
        _info = resultado ?? _describirObjetivo(col, fila);
        _modo = _Modo.atacar;
        _recalcular();
        if (_juego.escapePendiente == sel.id) {
          _alcanzables = _juego.casillasEscape(sel);
        }
      });
      return;
    }

    if (t != null && t.jugador == _juego.jugador) {
      setState(() => _seleccionar(t));
      return;
    }

    setState(_limpiarSeleccion);
  }

  void _confirmarDespliegue() {
    setState(() {
      _claseElegida = null;
      _limpiarSeleccion();
      _jugar(TipoComando.confirmarDespliegue);
    });
  }

  void _terminarTurno() {
    setState(() {
      _jugar(TipoComando.terminarTurno);
      _limpiarSeleccion();
      _info = _juego.ultimoEvento;
    });
  }

  void _confirmarConstruccion() {
    final sel = _seleccionado;
    if (sel == null) return;
    setState(() {
      if (_modo == _Modo.sacos && _marcadas.length == 1) {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoSacos)) {
          _info = 'Energía insuficiente (cuesta ${EstadoJuego.costoSacos} EN)';
          return;
        }
        final k = _marcadas.first;
        _info = _jugar(TipoComando.sacos,
                tanque: sel, col: k % columnas, fila: k ~/ columnas) ??
            'No se pudo construir ahí';
      } else if (_modo == _Modo.operacion && _marcadas.length == 2) {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoOperacion)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoOperacion} EN)';
          return;
        }
        _info = _jugar(TipoComando.operacion,
                tanque: sel, celdas: List<int>.from(_marcadas)) ??
            'No se pudo ejecutar la operación';
      } else if (_modo == _Modo.bombardeo && _marcadas.length == 1) {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoBombardeo)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoBombardeo} EN)';
          return;
        }
        final k = _marcadas.first;
        _info = _jugar(TipoComando.bombardeo,
                tanque: sel, col: k % columnas, fila: k ~/ columnas) ??
            'No se pudo bombardear ahí';
      } else if (_modo == _Modo.campo && _marcadas.length == 1) {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoCampo)) {
          _info = 'Energía insuficiente (cuesta ${EstadoJuego.costoCampo} EN)';
          return;
        }
        final k = _marcadas.first;
        _info = _jugar(TipoComando.campo,
                tanque: sel, col: k % columnas, fila: k ~/ columnas) ??
            'No hay casillas libres ahí';
      } else if (_modo == _Modo.estacion) {
        if (!_juego.puedePagarDisparo(sel, EstadoJuego.costoEstacion)) {
          _info =
              'Energía insuficiente (cuesta ${EstadoJuego.costoEstacion} EN)';
          return;
        }
        _info = _jugar(TipoComando.estacion, tanque: sel) ??
            'No se pudo crear la Estación';
      } else {
        return;
      }
      _marcadas.clear();
      _modo = _Modo.atacar;
      _recalcular();
    });
  }

  void _reiniciar() {
    setState(() {
      _juego.reiniciar();
      _claseElegida = null;
      _limpiarSeleccion();
    });
  }

  String get _textoEnergia {
    final j = _yo ?? _juego.jugador;
    final base = _juego.energia[j]!;
    final temp = j == _juego.jugador ? _juego.energiaTemporal : 0;
    return temp > 0 ? 'EN $base +$temp temporal' : 'EN $base';
  }

  String get _textoFichas =>
      'Fichas ${_juego.fichasRestantes}/${_juego.fichasTotales}';

  String get _textoEstado {
    final color = _juego.jugador == 1 ? 'verde' : 'rojo';
    final quien = _online == null
        ? 'Jugador ${_juego.jugador} ($color)'
        : (_esMiTurno
            ? 'Tu turno ($color)'
            : 'Turno de ${_online!.nombreRival} ($color)');
    if (_juego.fase == Fase.despliegue) {
      return '$quien · despliegue '
          '${_juego.contar(_juego.jugador)}/$tanquesPorJugador';
    }
    if (_juego.ganador != null) {
      final base = _online == null
          ? '¡Jugador ${_juego.ganador} gana la partida!'
          : (_juego.ganador == _yo
              ? '¡Victoria!'
              : 'Derrota: ${_online!.nombreRival} gana la partida');
      return _info.isEmpty ? base : '$base\n$_info';
    }
    final sel = _seleccionado;
    if (sel != null) {
      final c = sel.clase;
      final rampa = _juego.estaEnRampa(sel) ? ' (rampa)' : '';
      final base = '$quien · ${c.nombre} · HP ${sel.vida}/${c.vida} · '
          'Armor ${sel.armor}/${sel.armorMaximo} · Mov ${_juego.movimientoEfectivo(sel)} · '
          'Rango ${_juego.rangoEfectivo(sel)}$rampa · $_textoEnergia · $_textoFichas'
          '${_juego.trincherados.contains(sel.id) ? ' · Atrincherado' : ''}'
          '${_juego.pasivaArtilleriaActiva(sel) ? ' · Pasiva activa (ignora 20% Armor)' : ''}'
          '${[for (final e in _juego.estadosDe(sel)) ' · ${e.nombre}'].join()}';
      return _info.isEmpty ? base : '$base\n$_info';
    }
    final base = '$quien · $_textoEnergia · $_textoFichas · toca uno de tus tanques';
    return _info.isEmpty ? base : '$base\n$_info';
  }

  // ---------------- Interfaz ----------------

  Widget _panelInferior() {
    final sel = _seleccionado;
    return Container(
      color: _fondoBarra,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _textoEstado,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'monospace',
              letterSpacing: 1,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 8),
          ..._avisosOnline(),
          if (_online != null && _juego.ganador != null)
            FilledButton(
              onPressed: _salirDePartida,
              child: const Text('Volver al cuartel'),
            )
          else if (!_esMiTurno)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '⏳ TURNO DEL RIVAL',
                style: TextStyle(
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                  color: _ambar,
                ),
              ),
            )
          else if (_juego.fase == Fase.despliegue) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final c in ClaseTanque.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('${c.simbolo} ${c.nombre}'),
                        selected: _claseElegida == c,
                        onSelected: (_) => setState(() => _claseElegida = c),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _juego.contar(_juego.jugador) == tanquesPorJugador
                  ? _confirmarDespliegue
                  : null,
              child: Text(
                _online != null
                    ? 'Listo · confirmar despliegue'
                    : _juego.jugador == 1
                        ? 'Listo · pasar al Jugador 2'
                        : 'Listo · empezar partida',
              ),
            ),
          ] else ...[
            if (sel != null) ...[
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('Mover'),
                    selected: _modo == _Modo.mover,
                    onSelected: !_juego.puedeMover(sel)
                        ? null
                        : (_) => setState(() {
                              _modo = _Modo.mover;
                              _info = '';
                              _recalcular();
                            }),
                  ),
                  ChoiceChip(
                    label: Text(sel.clase == ClaseTanque.artilleria
                        ? 'Obús (${sel.clase.costoTiro})'
                        : 'Atacar'),
                    selected: _modo == _Modo.atacar,
                    onSelected: (_) => setState(() {
                      _modo = _Modo.atacar;
                      _info = '';
                      _recalcular();
                    }),
                  ),
                  if (sel.clase == ClaseTanque.pesado) ...[
                    ActionChip(
                      label: const Text('Girar ⟳'),
                      onPressed: () =>
                          setState(() => _jugar(TipoComando.girar, tanque: sel)),
                    ),
                    ActionChip(
                      label: Text('Trinchera (${EstadoJuego.costoTrinchera})'),
                      onPressed: _juego.trincherados.contains(sel.id)
                          ? null
                          : () => setState(() {
                                _info = _jugar(TipoComando.trinchera, tanque: sel) ??
                                    'No se pudo atrincherar (energía insuficiente o ya atrincherado)';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Embestida (${EstadoJuego.costoEmbestida})'),
                      selected: _modo == _Modo.embestida,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.embestida;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Sacrificio (${EstadoJuego.costoSacrificio})'),
                      selected: _modo == _Modo.sacrificio,
                      onSelected: !_juego.puedeDisparar(sel) ||
                              _juego.zonaTurnos.containsKey(sel.id)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.sacrificio;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                  ],
                  if (sel.clase == ClaseTanque.ligero) ...[
                    ChoiceChip(
                      label: Text('Perforante (${EstadoJuego.costoPerforante})'),
                      selected: _modo == _Modo.perforante,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.perforante;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Escape (${EstadoJuego.costoEscape})'),
                      selected: _modo == _Modo.escape,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.escape;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Ráfaga (${EstadoJuego.costoRafaga})'),
                      selected: _modo == _Modo.rafaga,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.rafaga;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                  ],
                  if (sel.clase == ClaseTanque.zapador) ...[
                    ChoiceChip(
                      label: Text('Sacos (${EstadoJuego.costoSacos})'),
                      selected: _modo == _Modo.sacos,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.sacos;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Rompemuros (${EstadoJuego.costoRompemuros})'),
                      selected: _modo == _Modo.rompemuros,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.rompemuros;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Operación (${EstadoJuego.costoOperacion})'),
                      selected: _modo == _Modo.operacion,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.operacion;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    if ((_modo == _Modo.sacos && _marcadas.length == 1) ||
                        (_modo == _Modo.operacion && _marcadas.length == 2))
                      ActionChip(
                        label: const Text('Confirmar ✔'),
                        onPressed: _confirmarConstruccion,
                      ),
                  ],
                  if (sel.clase == ClaseTanque.artilleria) ...[
                    ChoiceChip(
                      label: Text('Bengala (${EstadoJuego.costoBengala})'),
                      selected: _modo == _Modo.bengala,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.bengala;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label:
                          Text('Incendiaria (${EstadoJuego.costoIncendiaria})'),
                      selected: _modo == _Modo.incendiaria,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.incendiaria;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Bombardeo (${EstadoJuego.costoBombardeo})'),
                      selected: _modo == _Modo.bombardeo,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.bombardeo;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ActionChip(
                      label: const Text('Girar ⟳'),
                      onPressed: () =>
                          setState(() => _jugar(TipoComando.girar, tanque: sel)),
                    ),
                    if (_modo == _Modo.bombardeo && _marcadas.length == 1)
                      ActionChip(
                        label: const Text('Confirmar ✔'),
                        onPressed: _confirmarConstruccion,
                      ),
                  ],
                  if (sel.clase == ClaseTanque.soporte) ...[
                    ChoiceChip(
                      label: Text('Reparar (${EstadoJuego.costoReparacion})'),
                      selected: _modo == _Modo.reparacion,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.reparacion;
                                _info = '';
                                _cableId = null;
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Cable (${EstadoJuego.costoCable})'),
                      selected:
                          _modo == _Modo.cable || _modo == _Modo.cableDestino,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.cable;
                                _info = '';
                                _cableId = null;
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Estación (${EstadoJuego.costoEstacion})'),
                      selected: _modo == _Modo.estacion,
                      onSelected: !_juego.puedeEstacion(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.estacion;
                                _info = 'Zona 3x3 a tu alrededor: toca Confirmar';
                                _cableId = null;
                                _recalcular();
                              }),
                    ),
                    if (_modo == _Modo.cableDestino) ...[
                      ChoiceChip(
                        label: const Text('Jalar aliado'),
                        selected: _cableJalar,
                        onSelected: (_) => setState(() {
                          _cableJalar = true;
                          _info = '';
                          _recalcular();
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('Ir hacia él'),
                        selected: !_cableJalar,
                        onSelected: (_) => setState(() {
                          _cableJalar = false;
                          _info = '';
                          _recalcular();
                        }),
                      ),
                    ],
                    if (_modo == _Modo.estacion)
                      ActionChip(
                        label: const Text('Confirmar ✔'),
                        onPressed: _confirmarConstruccion,
                      ),
                  ],
                  if (sel.clase == ClaseTanque.sembrador) ...[
                    ChoiceChip(
                      label: Text('Mina (${EstadoJuego.costoMina})'),
                      selected: _modo == _Modo.mina,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.mina;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Lapa (${EstadoJuego.costoLapa})'),
                      selected: _modo == _Modo.lapa,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.lapa;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    ChoiceChip(
                      label: Text('Campo minado (${EstadoJuego.costoCampo})'),
                      selected: _modo == _Modo.campo,
                      onSelected: !_juego.puedeDisparar(sel)
                          ? null
                          : (_) => setState(() {
                                _modo = _Modo.campo;
                                _info = '';
                                _recalcular();
                              }),
                    ),
                    if (_modo == _Modo.campo && _marcadas.length == 1)
                      ActionChip(
                        label: const Text('Confirmar ✔'),
                        onPressed: _confirmarConstruccion,
                      ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              onPressed: _terminarTurno,
              child: const Text('Terminar turno'),
            ),
          ],
        ],
      ),
    );
  }

  /// Papel + cuadrícula + obstáculos + tanques + toques, sin girar.
  Widget _papel(double w, double h) {
    final gridW = w * 0.85;
    final cell = gridW / columnas;
    final gridH = cell * filas;
    final left = (w - gridW) / 2;
    final top = (h - gridH) / 2;

    // Vista previa del Bombardeo de Precisión (zona marcada, antes de confirmar)
    final sel = _seleccionado;
    final zonaBomb = (_modo == _Modo.bombardeo &&
            _marcadas.length == 1 &&
            sel != null &&
            sel.clase == ClaseTanque.artilleria)
        ? _juego.zonaBombardeo(
            sel, _marcadas.first % columnas, _marcadas.first ~/ columnas)
        : null;

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/papel_tablero.png',
              fit: BoxFit.fill,
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: gridW,
            height: gridH,
            child: GestureDetector(
              onTapUp: (d) {
                final col = (d.localPosition.dx / cell).floor();
                final fila = (d.localPosition.dy / cell).floor();
                if (col >= 0 && col < columnas && fila >= 0 && fila < filas) {
                  _alTocar(col, fila);
                }
              },
              child: CustomPaint(
                painter: _TableroPainter(
                  cell: cell,
                  juego: _juego,
                  seleccionado: _seleccionado,
                  alcanzables: _alcanzables,
                  rango: _rango,
                  jugadorDespliegue:
                      _juego.fase == Fase.despliegue ? _juego.jugador : null,
                  esteOeste: _esteOeste,
                  verComo: _yo,
                  previewZona: _modo == _Modo.sacrificio,
                  previewEstacion: _modo == _Modo.estacion,
                  marcadas: _modo == _Modo.bombardeo
                      ? const <int>{}
                      : _marcadas.toSet(),
                  bombCentro: zonaBomb?.centro ?? const <int>{},
                  bombLados: zonaBomb?.lados ??
                      ((_modo == _Modo.campo && _marcadas.length == 1)
                          ? _juego.cuadranteCampo(
                              _marcadas.first % columnas,
                              _marcadas.first ~/ columnas)
                          : const <int>{}),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_online != null && _juego.ganador != null && !_finMostrado) {
      _finMostrado = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _mostrarFin());
    }
    final pantalla = Scaffold(
      backgroundColor: _fondoTablero,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(_online == null
            ? 'Tablero $columnas x $filas'
            : 'vs ${_online!.nombreRival}'),
        backgroundColor: _fondoBarra,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (_online == null)
            IconButton(
              tooltip: 'Reiniciar partida de prueba',
              icon: const Icon(Icons.restart_alt),
              onPressed: _reiniciar,
            )
          else
            IconButton(
              tooltip: 'Salir de la partida',
              icon: const Icon(Icons.exit_to_app),
              onPressed: _pedirSalida,
            ),
          IconButton(
            tooltip: 'Girar orientación (prueba)',
            icon: const Icon(Icons.screen_rotation_alt),
            onPressed: _alternarOrientacion,
          ),
          IconButton(
            tooltip: 'Centrar mapa',
            icon: const Icon(Icons.center_focus_strong),
            onPressed: () => setState(() => _centrar = true),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Fondo: mapa topográfico (queda fijo detrás del tablero)
          Positioned.fill(
            child: Image.asset(
              'assets/images/fondo_mapa.jpg',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, c) {
                final vw = c.maxWidth;
                final vh = c.maxHeight;
                _tamanoViewport = Size(vw, vh);

                // Tamaño del papel (sin girar). Siempre cubre la pantalla.
                final necesario =
                    _esteOeste ? vh : vh * _papelAncho / _papelAlto;
                final escalaMapa =
                    _esteOeste ? ampliacionEsteOeste : ampliacion;
                final pw = math.max(vw * escalaMapa, necesario);
                final ph = pw * _papelAlto / _papelAncho;

                // Tamaño que ocupa en pantalla, ya girado si hace falta.
                final dw = _esteOeste ? ph : pw;
                final dh = _esteOeste ? pw : ph;

                if (_centrar) {
                  _centrar = false;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _ctrl.value = Matrix4.translationValues(
                      -(dw - vw) / 2,
                      -(dh - vh) / 2,
                      0,
                    );
                  });
                }

                final papel = _papel(pw, ph);

                return InteractiveViewer(
                  transformationController: _ctrl,
                  constrained: false,
                  minScale: _zoomMinimoOrientacion,
                  maxScale: _zoomMaximoOrientacion,
                  boundaryMargin: EdgeInsets.symmetric(vertical: vh),
                  onInteractionStart: _alIniciarInteraccion,
                  onInteractionUpdate: _actualizarInteraccion,
                  onInteractionEnd: _alTerminarInteraccion,
                  child: _esteOeste
                      ? RotatedBox(quarterTurns: 1, child: papel)
                      : papel,
                );
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(top: false, child: _panelInferior()),
          ),
        ],
      ),
    );
    if (_online == null) return pantalla;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pedirSalida();
      },
      child: pantalla,
    );
  }
}

class _TableroPainter extends CustomPainter {
  final double cell;
  final EstadoJuego juego;
  final Tanque? seleccionado;
  final Set<int> alcanzables;
  final RangoAtaque? rango;
  final int? jugadorDespliegue;
  final bool esteOeste;
  final bool previewZona;
  final bool previewEstacion;
  final Set<int> marcadas;
  final Set<int> bombCentro;
  final Set<int> bombLados;

  /// Quién está mirando (online). Null = el jugador de turno (práctica).
  final int? verComo;

  _TableroPainter({
    required this.cell,
    required this.juego,
    required this.seleccionado,
    required this.alcanzables,
    required this.rango,
    required this.jugadorDespliegue,
    required this.esteOeste,
    required this.previewZona,
    required this.previewEstacion,
    required this.marcadas,
    required this.bombCentro,
    required this.bombLados,
    this.verComo,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final zonaArriba = Rect.fromLTWH(0, 0, size.width, cell * filasDespliegue);
    final zonaAbajo = Rect.fromLTWH(
      0,
      cell * (filas - filasDespliegue),
      size.width,
      cell * filasDespliegue,
    );

    // Zonas de despliegue (2 filas arriba y 2 abajo)
    final zona = Paint()..color = _verde.withValues(alpha: 0.22);
    canvas.drawRect(zonaArriba, zona);
    canvas.drawRect(zonaAbajo, zona);

    // Zona activa durante el despliegue
    if (jugadorDespliegue != null) {
      canvas.drawRect(
        jugadorDespliegue == 1 ? zonaAbajo : zonaArriba,
        Paint()..color = _ambar.withValues(alpha: 0.16),
      );
    }

    // Obstáculos
    for (final o in juego.obstaculos) {
      _dibujarObstaculo(canvas, o);
    }

    // Escombros (casillas arruinadas por Rompemuros)
    for (final k in juego.ruinas.keys) {
      _dibujarEscombros(canvas, _rectDe(k));
    }

    // Minas: las de presión solo las ve su dueño; las de fragmentación, todos
    for (final e in juego.minas.entries) {
      final m = e.value;
      if (m.tipo == TipoMina.presion &&
          m.dueno != (verComo ?? juego.jugador)) {
        continue;
      }
      _dibujarMina(canvas, _rectDe(e.key), m);
    }

    // Bengalas activas y casillas en llamas
    for (final b in juego.bengalas) {
      _dibujarBengala(canvas, b);
    }
    for (final k in juego.fuegos.keys) {
      _dibujarFuego(canvas, _rectDe(k));
    }

    // Estaciones de Reabastecimiento (zona verde sanitaria)
    for (final e in juego.estaciones) {
      _dibujarEstacion(canvas, e.col, e.fila);
    }

    final sel = seleccionado;
    if (previewEstacion &&
        sel != null &&
        sel.clase == ClaseTanque.soporte) {
      _dibujarEstacion(canvas, sel.col, sel.fila, vistaPrevia: true);
    }
    // Zona azul del Sacrificio del Comandante (activa y vista previa)
    for (final id in juego.zonaTurnos.keys) {
      final p = juego.tanquePorId(id);
      if (p != null) _dibujarZonaAzul(canvas, p.col, p.fila);
    }
    if (previewZona &&
        sel != null &&
        !juego.zonaTurnos.containsKey(sel.id)) {
      _dibujarZonaAzul(canvas, sel.col, sel.fila);
    }

    // Casillas alcanzables (movimiento, ámbar)
    for (final k in alcanzables) {
      final rect = _rectDe(k);
      canvas.drawRect(rect, Paint()..color = _ambar.withValues(alpha: 0.30));
      canvas.drawRect(
        rect.deflate(2),
        Paint()
          ..color = _ambar
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // Casillas marcadas para construir (muros por confirmar)
    for (final k in marcadas) {
      final rect = _rectDe(k);
      canvas.drawRect(rect, Paint()..color = _verde.withValues(alpha: 0.35));
      canvas.drawRect(
        rect.deflate(cell * 0.18),
        Paint()
          ..color = _verde
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.5, cell * 0.05),
      );
    }

    // Vista previa del Bombardeo de Precisión (centro más intenso que los lados)
    for (final k in bombLados) {
      final rect = _rectDe(k);
      canvas.drawRect(rect, Paint()..color = _rojo.withValues(alpha: 0.20));
      canvas.drawRect(
        rect.deflate(cell * 0.1),
        Paint()
          ..color = _rojo.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, cell * 0.03),
      );
    }
    for (final k in bombCentro) {
      final rect = _rectDe(k);
      canvas.drawRect(rect, Paint()..color = _rojo.withValues(alpha: 0.38));
      canvas.drawRect(
        rect.deflate(cell * 0.1),
        Paint()
          ..color = _rojo
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.0, cell * 0.045),
      );
    }

    // Rango de ataque (rojo)
    if (rango != null) _dibujarRango(canvas, rango!);

    // Cuadrícula
    final linea = Paint()
      ..color = _tinta.withValues(alpha: 0.6)
      ..strokeWidth = 1.2;
    for (int i = 0; i <= columnas; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, cell * filas), linea);
    }
    for (int j = 0; j <= filas; j++) {
      canvas.drawLine(Offset(0, j * cell), Offset(cell * columnas, j * cell), linea);
    }

    // Borde exterior
    canvas.drawRect(
      Rect.fromLTWH(0, 0, cell * columnas, cell * filas),
      Paint()
        ..color = _tinta.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Tanques
    for (final t in juego.tanques) {
      _dibujarTanque(canvas, t);
    }

    // Marca del tanque seleccionado
    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTWH(sel.col * cell, sel.fila * cell, cell, cell).deflate(2),
        Paint()
          ..color = _ambar
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5,
      );
    }

    // La pasiva se pinta al final para quedar por encima de todas las capas.
    if (sel != null && sel.clase == ClaseTanque.pesado) {
      final centro = Offset((sel.col + 0.5) * cell, (sel.fila + 0.5) * cell);
      final dir = Offset(sel.dirCol.toDouble(), sel.dirFila.toDouble());
      final lateral = Offset(-dir.dy, dir.dx);
      final radio = cell * 0.45;
      final centroArco = centro + dir * (cell * 0.45);
      final inicio = centroArco - lateral * radio;
      final fin = centroArco + lateral * radio;
      const factorControl = 0.55228475;
      final arco = Path()
        ..moveTo(inicio.dx, inicio.dy)
        ..cubicTo(
          (inicio + dir * (radio * factorControl)).dx,
          (inicio + dir * (radio * factorControl)).dy,
          (fin + dir * (radio * factorControl)).dx,
          (fin + dir * (radio * factorControl)).dy,
          fin.dx,
          fin.dy,
        );
      canvas.drawPath(
        arco,
        Paint()
          ..color = sel.jugador == 1 ? _verde : _rojo
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.5, cell * 0.075)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// Mina: disco oscuro con púas. La de presión lleva un punto ámbar;
  /// la de fragmentación, uno rojo.
  void _dibujarMina(Canvas canvas, Rect rect, Mina m) {
    final c = rect.center;
    final r = cell * 0.16;
    final pua = Paint()
      ..color = _tinta
      ..strokeWidth = math.max(1.5, cell * 0.04)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * (r * 0.9),
        c + Offset(math.cos(a), math.sin(a)) * (r * 1.6),
        pua,
      );
    }
    canvas.drawCircle(c, r, Paint()..color = _tinta);
    canvas.drawCircle(
      c,
      r * 0.4,
      Paint()..color = m.tipo == TipoMina.presion ? _ambar : _rojo,
    );
  }

  /// Casilla en llamas (Munición Incendiaria).
  void _dibujarFuego(Canvas canvas, Rect rect) {
    canvas.drawRect(rect, Paint()..color = _fuego.withValues(alpha: 0.28));
    final c = rect.center;
    final llama = Path()
      ..moveTo(c.dx, c.dy - cell * 0.32)
      ..quadraticBezierTo(
          c.dx + cell * 0.28, c.dy - cell * 0.02, c.dx + cell * 0.13, c.dy + cell * 0.22)
      ..quadraticBezierTo(c.dx, c.dy + cell * 0.32, c.dx - cell * 0.13, c.dy + cell * 0.22)
      ..quadraticBezierTo(
          c.dx - cell * 0.28, c.dy - cell * 0.02, c.dx, c.dy - cell * 0.32)
      ..close();
    canvas.drawPath(llama, Paint()..color = _fuego.withValues(alpha: 0.9));
    canvas.drawCircle(
      c + Offset(0, cell * 0.12),
      cell * 0.08,
      Paint()..color = _bengala,
    );
  }

  /// Bengala (Disparo de Iluminación): 3x3 iluminado.
  void _dibujarBengala(Canvas canvas, Bengala b) {
    final rect = Rect.fromLTRB(
      math.max(0, b.col - 1) * cell,
      math.max(0, b.fila - 1) * cell,
      math.min(columnas, b.col + 2) * cell,
      math.min(filas, b.fila + 2) * cell,
    );
    canvas.drawRect(rect, Paint()..color = _bengala.withValues(alpha: 0.16));
    canvas.drawRect(
      rect.deflate(cell * 0.04),
      Paint()
        ..color = _bengala.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2.0, cell * 0.04),
    );
    // Destello en el centro
    final c = Offset((b.col + 0.5) * cell, (b.fila + 0.5) * cell);
    final rayo = Paint()
      ..color = _bengala
      ..strokeWidth = math.max(1.5, cell * 0.035)
      ..strokeCap = StrokeCap.round;
    final r = cell * 0.18;
    canvas.drawLine(c + Offset(-r, 0), c + Offset(r, 0), rayo);
    canvas.drawLine(c + Offset(0, -r), c + Offset(0, r), rayo);
    canvas.drawLine(c + Offset(-r * 0.7, -r * 0.7), c + Offset(r * 0.7, r * 0.7), rayo);
    canvas.drawLine(c + Offset(-r * 0.7, r * 0.7), c + Offset(r * 0.7, -r * 0.7), rayo);
  }

  /// Insignia de cada estado del tanque (arriba a la derecha de la casilla).
  void _dibujarEstados(Canvas canvas, Tanque t) {
    // Carga Lapa pegada: punto rojo con una L, abajo a la izquierda
    if (juego.lapas.containsKey(t.id)) {
      final radio = cell * 0.12;
      final c = Offset(t.col * cell + radio + cell * 0.03,
          (t.fila + 1) * cell - radio - cell * 0.16);
      canvas.drawCircle(c, radio + 1, Paint()..color = _papelClaro);
      canvas.drawCircle(c, radio, Paint()..color = _rojo);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      if (esteOeste) canvas.rotate(-math.pi / 2);
      final tp = TextPainter(
        text: TextSpan(
          text: 'L',
          style: TextStyle(
            fontSize: radio * 1.35,
            color: _papelClaro,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
    final lista = juego.estadosDe(t).toList();
    if (lista.isEmpty) return;
    final radio = cell * 0.12;
    for (var i = 0; i < lista.length; i++) {
      final c = Offset(
        (t.col + 1) * cell - radio - cell * 0.03 - i * radio * 2.2,
        t.fila * cell + radio + cell * 0.03,
      );
      canvas.drawCircle(c, radio + 1, Paint()..color = _papelClaro);
      canvas.drawCircle(c, radio, Paint()..color = _tinta);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      if (esteOeste) canvas.rotate(-math.pi / 2);
      final tp = TextPainter(
        text: TextSpan(
          text: lista[i].nombre[0], // A de Atascado, etc.
          style: TextStyle(
            fontSize: radio * 1.35,
            color: _papelClaro,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }
  }

  void _dibujarEscombros(Canvas canvas, Rect rect) {
    final piedra = Paint()..color = const Color(0xCC6B665C);
    final c = rect.center;
    for (final o in const [
      Offset(-0.22, -0.10),
      Offset(0.15, -0.20),
      Offset(0.05, 0.18),
      Offset(-0.12, 0.25),
      Offset(0.25, 0.12),
      Offset(-0.28, 0.08),
    ]) {
      canvas.drawCircle(c + o * cell, cell * 0.07, piedra);
    }
  }

  Rect _rectDe(int k) =>
      Rect.fromLTWH((k % columnas) * cell, (k ~/ columnas) * cell, cell, cell);

  // ---------- Rango de ataque: rayado + contorno punteado + sombra + anillos ----------

  void _dibujarRango(Canvas canvas, RangoAtaque r) {
    // Tinte suave en las casillas con visión
    final visibles = Path();
    for (final k in r.visibles) {
      visibles.addRect(_rectDe(k));
    }
    canvas.drawPath(visibles, Paint()..color = _rojo.withValues(alpha: 0.08));

    // Rayado diagonal (interlineado) dentro de las casillas con visión
    canvas.save();
    canvas.clipPath(visibles);
    final lapiz = Paint()
      ..color = _rojo.withValues(alpha: 0.45)
      ..strokeWidth = math.max(1.5, cell * 0.025);
    final paso = cell * 0.14;
    final ancho = cell * columnas;
    final alto = cell * filas;
    for (double d = -alto; d < ancho; d += paso) {
      canvas.drawLine(Offset(d, alto), Offset(d + alto, 0), lapiz);
    }
    canvas.restore();

    // Sombra de visión: casillas en rango que un muro tapa
    final sombra = Paint()..color = const Color(0x55303030);
    final cruz = Paint()
      ..color = const Color(0x99303030)
      ..strokeWidth = math.max(1.5, cell * 0.03)
      ..strokeCap = StrokeCap.round;
    for (final k in r.alcance.difference(r.visibles)) {
      final rect = _rectDe(k);
      canvas.drawRect(rect, sombra);
      final m = cell * 0.22;
      canvas.drawLine(
        Offset(rect.left + m, rect.top + m),
        Offset(rect.right - m, rect.bottom - m),
        cruz,
      );
      canvas.drawLine(
        Offset(rect.right - m, rect.top + m),
        Offset(rect.left + m, rect.bottom - m),
        cruz,
      );
    }

    // Contorno punteado. Si hay rampa, el rango base va fuerte y el extra más tenue
    final conOrigen = <int>{...r.alcance, r.origen};
    final soloBase = <int>{...r.alcance.difference(r.bonus), r.origen};
    final trazoFuerte = Paint()
      ..color = _rojo
      ..strokeWidth = math.max(2.0, cell * 0.035)
      ..strokeCap = StrokeCap.butt;
    if (r.bonus.isNotEmpty) {
      final trazoTenue = Paint()
        ..color = _rojo.withValues(alpha: 0.5)
        ..strokeWidth = math.max(1.5, cell * 0.025)
        ..strokeCap = StrokeCap.butt;
      _contornoPunteado(canvas, conOrigen, trazoTenue);
      _contornoPunteado(canvas, soloBase, trazoFuerte);
    } else {
      _contornoPunteado(canvas, conOrigen, trazoFuerte);
    }

    // Anillo en los objetivos válidos
    final anillo = Paint()
      ..color = _rojo
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, cell * 0.04);
    for (final k in r.objetivos) {
      canvas.drawCircle(_rectDe(k).center, cell * 0.44, anillo);
    }
  }

  /// Dibuja con rayitas el borde exterior de un conjunto de casillas.
  /// Cada lado de casilla lleva exactamente 5 rayitas, así se enlazan al doblar.
  void _contornoPunteado(Canvas canvas, Set<int> celdas, Paint paint) {
    final paso = cell * 0.2;
    final trazo = cell * 0.12;

    bool fuera(int c, int f) =>
        c < 0 || c >= columnas || f < 0 || f >= filas ||
        !celdas.contains(EstadoJuego.idx(c, f));

    void horizontal(double x, double y) {
      for (int i = 0; i < 5; i++) {
        canvas.drawLine(
          Offset(x + i * paso, y),
          Offset(x + i * paso + trazo, y),
          paint,
        );
      }
    }

    void vertical(double x, double y) {
      for (int i = 0; i < 5; i++) {
        canvas.drawLine(
          Offset(x, y + i * paso),
          Offset(x, y + i * paso + trazo),
          paint,
        );
      }
    }

    for (final k in celdas) {
      final c = k % columnas;
      final f = k ~/ columnas;
      final x = c * cell;
      final y = f * cell;
      if (fuera(c, f - 1)) horizontal(x, y);
      if (fuera(c, f + 1)) horizontal(x, y + cell);
      if (fuera(c - 1, f)) vertical(x, y);
      if (fuera(c + 1, f)) vertical(x + cell, y);
    }
  }

  // ---------- Obstáculos dibujados en código (se pueden cambiar por tus PNG) ----------

  void _dibujarObstaculo(Canvas canvas, Obstaculo o) {
    final x = o.col * cell;
    final y = o.fila * cell;
    final rect = Rect.fromLTWH(x, y, cell, cell);
    final borde = Paint()
      ..style = PaintingStyle.stroke
      ..color = _tinta
      ..strokeWidth = math.max(1.5, cell * 0.025);
    final fino = Paint()
      ..color = _tinta.withValues(alpha: 0.5)
      ..strokeWidth = math.max(1.0, cell * 0.018);

    switch (o.tipo) {
      case TipoObstaculo.sacos: {
        final r = rect.deflate(cell * 0.12);
        final rr = RRect.fromRectAndRadius(r, Radius.circular(cell * 0.06));
        canvas.drawRRect(rr, Paint()..color = const Color(0xFFB59B6B));
        canvas.drawRRect(rr, borde);
        for (int i = 1; i < 3; i++) {
          final yy = r.top + r.height * i / 3;
          canvas.drawLine(Offset(r.left, yy), Offset(r.right, yy), fino);
        }
        canvas.drawLine(
          Offset(r.center.dx, r.top),
          Offset(r.center.dx, r.top + r.height / 3),
          fino,
        );
        canvas.drawLine(
          Offset(r.left + r.width * 0.3, r.top + r.height / 3),
          Offset(r.left + r.width * 0.3, r.top + r.height * 2 / 3),
          fino,
        );
        canvas.drawLine(
          Offset(r.left + r.width * 0.7, r.top + r.height * 2 / 3),
          Offset(r.left + r.width * 0.7, r.bottom),
          fino,
        );
        break;
      }
      case TipoObstaculo.ladrillo: {
        final r = rect.deflate(cell * 0.12);
        canvas.drawRect(r, Paint()..color = const Color(0xFF9C4A32));
        for (int i = 1; i < 4; i++) {
          final yy = r.top + r.height * i / 4;
          canvas.drawLine(Offset(r.left, yy), Offset(r.right, yy), fino);
        }
        for (int i = 0; i < 4; i++) {
          final yy = r.top + r.height * i / 4;
          final desfase = i.isEven ? 0.33 : 0.66;
          final xx = r.left + r.width * desfase;
          canvas.drawLine(Offset(xx, yy), Offset(xx, yy + r.height / 4), fino);
        }
        canvas.drawRect(r, borde);
        break;
      }
      case TipoObstaculo.tinta: {
        final mancha = Paint()..color = const Color(0xE61C1B1A);
        final c = rect.center;
        canvas.drawCircle(c, cell * 0.30, mancha);
        canvas.drawCircle(c + Offset(-cell * 0.2, cell * 0.12), cell * 0.16, mancha);
        canvas.drawCircle(c + Offset(cell * 0.22, -cell * 0.16), cell * 0.14, mancha);
        canvas.drawCircle(c + Offset(cell * 0.16, cell * 0.24), cell * 0.09, mancha);
        break;
      }
      case TipoObstaculo.cafe: {
        final c = rect.center;
        canvas.drawCircle(
          c,
          cell * 0.32,
          Paint()..color = const Color(0xFF8B5E3C).withValues(alpha: 0.22),
        );
        canvas.drawCircle(
          c,
          cell * 0.32,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFF8B5E3C).withValues(alpha: 0.85)
            ..strokeWidth = cell * 0.05,
        );
        canvas.drawCircle(
          c + Offset(cell * 0.28, -cell * 0.2),
          cell * 0.05,
          Paint()..color = const Color(0xFF8B5E3C).withValues(alpha: 0.8),
        );
        break;
      }
      case TipoObstaculo.rampa: {
        final r = rect.deflate(cell * 0.1);
        canvas.drawRect(r, Paint()..color = const Color(0xFFB8B3A8));
        final franja = Paint()..color = const Color(0xFFD9A521);
        canvas.drawRect(
          Rect.fromLTWH(r.left, r.top, r.width * 0.14, r.height),
          franja,
        );
        canvas.drawRect(
          Rect.fromLTWH(r.right - r.width * 0.14, r.top, r.width * 0.14, r.height),
          franja,
        );
        canvas.drawRect(r, borde);
        break;
      }
    }

    // Marca de dueño: puntito del color del equipo en los muros construidos
    final dueno = juego.duenos[o];
    if (dueno != null) {
      final p = Offset(x + cell * 0.2, y + cell * 0.2);
      canvas.drawCircle(p, cell * 0.075, Paint()..color = dueno == 1 ? _verde : _rojo);
      canvas.drawCircle(
        p,
        cell * 0.075,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = _papelClaro
          ..strokeWidth = math.max(1.0, cell * 0.02),
      );
    }

    // Barra de vida de los muros dañados
    if (o.tipo.esMuro && o.hp < Obstaculo.hpMuro) {
      final bw = cell * 0.66;
      final bh = cell * 0.07;
      final bx = x + (cell - bw) / 2;
      final by = y + cell * 0.88;
      canvas.drawRect(Rect.fromLTWH(bx, by, bw, bh), Paint()..color = _tinta);
      final frac = (o.hp / Obstaculo.hpMuro).clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTWH(bx, by, bw * frac, bh),
        Paint()..color = _ambar,
      );
    }
  }

  // ---------- Estación de Reabastecimiento (3x3 verde con cruz) ----------

  void _dibujarEstacion(Canvas canvas, int col, int fila,
      {bool vistaPrevia = false}) {
    final celdas = <int>{
      for (var dc = -1; dc <= 1; dc++)
        for (var df = -1; df <= 1; df++)
          if (col + dc >= 0 &&
              col + dc < columnas &&
              fila + df >= 0 &&
              fila + df < filas)
            EstadoJuego.idx(col + dc, fila + df),
    };
    final relleno = Path();
    for (final k in celdas) {
      relleno.addRect(_rectDe(k));
    }
    canvas.drawPath(
      relleno,
      Paint()..color = _sanitario.withValues(alpha: vistaPrevia ? 0.14 : 0.22),
    );
    _contornoPunteado(
      canvas,
      celdas,
      Paint()
        ..color = _sanitario
        ..strokeWidth = math.max(2.0, cell * 0.045)
        ..strokeCap = StrokeCap.butt,
    );

    // Cruz sanitaria en el centro de la zona
    final c = Offset((col + 0.5) * cell, (fila + 0.5) * cell);
    final brazo = cell * 0.30;
    final grosor = cell * 0.10;
    final cruz = Paint()..color = _papelClaro.withValues(alpha: 0.85);
    canvas.drawRect(
      Rect.fromCenter(center: c, width: brazo * 2, height: grosor),
      cruz,
    );
    canvas.drawRect(
      Rect.fromCenter(center: c, width: grosor, height: brazo * 2),
      cruz,
    );
    final borde = Paint()
      ..style = PaintingStyle.stroke
      ..color = _sanitario
      ..strokeWidth = math.max(1.2, cell * 0.02);
    canvas.drawRect(
      Rect.fromCenter(center: c, width: brazo * 2, height: grosor),
      borde,
    );
    canvas.drawRect(
      Rect.fromCenter(center: c, width: grosor, height: brazo * 2),
      borde,
    );
  }

  // ---------- Zona azul (borde como pincelada) ----------

  void _dibujarZonaAzul(Canvas canvas, int col, int fila) {
    final rect = Rect.fromLTRB(
      math.max(0, col - 2) * cell,
      math.max(0, fila - 2) * cell,
      math.min(columnas, col + 3) * cell,
      math.min(filas, fila + 3) * cell,
    );
    canvas.drawRect(rect, Paint()..color = _azulZona.withValues(alpha: 0.14));

    final azar = math.Random(col * 31 + fila * 17 + 5);
    final pts = <Offset>[];
    void borde(Offset a, Offset b, Offset normal) {
      final largo = (b - a).distance;
      final n = math.max(2, (largo / (cell * 0.1)).round());
      for (var i = 0; i < n; i++) {
        final p = Offset.lerp(a, b, i / n)!;
        final j = (azar.nextDouble() - 0.5) * cell * 0.08;
        pts.add(p + normal * j);
      }
    }

    final r = rect.deflate(cell * 0.04);
    borde(r.topLeft, r.topRight, const Offset(0, 1));
    borde(r.topRight, r.bottomRight, const Offset(1, 0));
    borde(r.bottomRight, r.bottomLeft, const Offset(0, 1));
    borde(r.bottomLeft, r.topLeft, const Offset(1, 0));

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = cell * 0.08
        ..color = _azulZona.withValues(alpha: 0.45),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = cell * 0.03
        ..color = _azulZona.withValues(alpha: 0.95),
    );
  }

  // ---------- Tanques ----------

  void _dibujarTanque(Canvas canvas, Tanque t) {
    final centro =
        Offset((t.col + 0.5) * cell, (t.fila + 0.5) * cell - cell * 0.04);
    final r = cell * 0.36;
    final ya = juego.sinAcciones(t);
    final base = t.jugador == 1 ? _verde : _sello;
    final color = ya ? base.withValues(alpha: 0.55) : base;

    canvas.drawCircle(centro, r + 1.5, Paint()..color = _tinta);
    canvas.drawCircle(centro, r, Paint()..color = color);
    canvas.drawCircle(
      centro,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = _papelClaro.withValues(alpha: ya ? 0.5 : 0.9)
        ..strokeWidth = cell * 0.035,
    );

    // Símbolo de la clase (se contra-gira para que siempre se lea derecho)
    canvas.save();
    canvas.translate(centro.dx, centro.dy);
    if (esteOeste) canvas.rotate(-math.pi / 2);
    final tp = TextPainter(
      text: TextSpan(
        text: t.clase.simbolo,
        style: TextStyle(
          fontSize: cell * 0.40,
          color: _papelClaro,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();

    // Barra de vida
    final bw = cell * 0.66;
    final bh = cell * 0.07;
    final bx = t.col * cell + (cell - bw) / 2;
    final by = t.fila * cell + cell * 0.86;
    canvas.drawRect(Rect.fromLTWH(bx, by, bw, bh), Paint()..color = _tinta);
    final frac = (t.vida / t.clase.vida).clamp(0.0, 1.0);
    canvas.drawRect(
      Rect.fromLTWH(bx, by, bw * frac, bh),
      Paint()..color = _ambar,
    );

    _dibujarEstados(canvas, t);
  }

  @override
  bool shouldRepaint(covariant _TableroPainter old) => true;
}
