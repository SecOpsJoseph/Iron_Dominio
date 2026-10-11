import 'dart:math' as math;

import 'comando.dart';
import 'estado_tanque.dart';
import 'obstaculo_modelo.dart';
import 'tanque.dart';

// Tamaño del tablero (GDD: 9 x 11).
const int columnas = 9;
const int filas = 11;
const int filasDespliegue = 2;
const int tanquesPorJugador = 3;

enum Fase { despliegue, juego }

/// Resultado de calcular el rango de ataque de un tanque.
class RangoAtaque {
  final int origen; // casilla del tanque
  final Set<int> alcance; // todo el rombo (sin la casilla del tanque)
  final Set<int> visibles; // dentro del rombo y con línea de visión
  final Set<int> objetivos; // visibles con enemigo o muro
  final Set<int> bonus; // casillas extra por estar sobre una rampa

  const RangoAtaque({
    required this.origen,
    required this.alcance,
    required this.visibles,
    required this.objetivos,
    required this.bonus,
  });
}

/// Bengala del Artillero: 3x3 donde los muros de sacos del rival no cuentan.
class Bengala {
  final int col; // centro del 3x3
  final int fila;
  final int jugador; // quién la lanzó
  int turnos; // turnos suyos que le quedan

  Bengala({
    required this.col,
    required this.fila,
    required this.jugador,
    required this.turnos,
  });

  bool cubre(int c, int f) => (c - col).abs() <= 1 && (f - fila).abs() <= 1;
}

enum TipoMina { presion, fragmentacion }

/// Mina en el tablero. La de presión es oculta (solo la ve su dueño);
/// las de fragmentación del Campo Minado se ven para todos.
class Mina {
  final TipoMina tipo;
  final int dueno;
  const Mina(this.tipo, this.dueno);
}

/// Carga Lapa pegada a un tanque enemigo (viaja con él).
class Lapa {
  final int sembradorId;
  final int dueno;
  const Lapa(this.sembradorId, this.dueno);
}

/// Estación de Reabastecimiento del Soporte: zona 3x3 fija en el tablero.
class Estacion {
  final int col; // centro del 3x3
  final int fila;
  final int jugador; // quién la creó
  int turnos; // turnos suyos que le quedan

  Estacion({
    required this.col,
    required this.fila,
    required this.jugador,
    required this.turnos,
  });

  bool cubre(int c, int f) => (c - col).abs() <= 1 && (f - fila).abs() <= 1;
}

/// Reglas y estado de la partida, sin nada de pantalla.
/// Más adelante, en el modo online, cada acción se aplicará igual en los dos celulares.
class EstadoJuego {
  Fase fase = Fase.despliegue;
  int jugador = 1; // 1 = abajo, 2 = arriba
  final List<Tanque> tanques = [];
  final List<Obstaculo> obstaculos = [];
  final Set<int> movidos = {};
  final Set<int> dispararon = {};
  // Tanques que se movieron en algún momento del turno (para la Energía Volátil)
  final Set<int> movidosTurno = {};

  // Sistema Relevo de Acción: 1 ficha por tanque + reserva común de los destruidos.
  // Cada ficha permite un ciclo completo (mover + disparar).
  final Set<int> fichaPropiaUsada = {}; // tanques que ya gastaron su ficha propia
  final Set<int> ciclosAbiertos = {}; // tanques con un ciclo en curso
  int reservaTotal = 0; // fichas heredadas de tanques destruidos (se fija al empezar el turno)
  int reservaUsada = 0;
  int? ganador; // jugador que ganó la partida, null si sigue en juego

  // Tanques que se quedaron quietos en su turno anterior (dan EN temporal en el siguiente).
  final Map<int, Set<int>> quietos = {1: {}, 2: {}};

  // Energía (EN): la base se acumula; la temporal solo vale en el turno actual.
  final Map<int, int> energia = {1: 0, 2: 0};
  int energiaTemporal = 0;
  static const int maxEnergiaTemporal = 5;

  // Habilidades del Ligero
  static const int costoPerforante = 2;
  static const int costoEscape = 2;
  static const int costoRafaga = 4;

  // Habilidades del Pesado
  static const int costoTrinchera = 2;
  static const int costoEmbestida = 2;
  static const int costoSacrificio = 4;
  final Map<int, int> zonaTurnos = {}; // id del Pesado → turnos suyos que le quedan
  final Map<int, int> zonaAcumulado = {}; // daño mitigado por la zona
  final Set<int> trincherados = {}; // atrincherados hasta su siguiente turno
  int? escapePendiente; // tanque que acaba de disparar con Maniobra de Escape
  // Habilidades del Zapador
  static const int costoSacos = 2;
  static const int costoRompemuros = 2;
  static const int costoOperacion = 4;
  static const int curacionMuro = 15;
  // Muros construidos → jugador dueño (los muros del mapa son neutrales)
  final Map<Obstaculo, int> duenos = {};
  // Casillas arruinadas por Rompemuros → turnos que les quedan
  final Map<int, int> ruinas = {};

  // Habilidades del Artillero
  static const int costoBengala = 1;
  static const int costoIncendiaria = 2;
  static const int costoBombardeo = 4;
  static const int rangoBengala = 6;
  static const int rangoBombardeo = 5; // máximo del centro, 3x4 y orientado
  static const int danoIncendiaria = 40;
  static const int danoFuego = 20; // directo a la vida (ignora Armor)
  static const int turnosFuego = 3; // turnos del dueño que arde la casilla
  static const int turnosBengala = 2; // turnos del dueño que dura la bengala
  static const int armorBengala = 20; // Armor que pierden los enemigos expuestos
  static const double armorIgnoradoPasiva = 0.20;
  static const int danoBombardeoCentro = 80;
  static const int danoBombardeoLado = 40;
  static const int danoBombardeoMuro = 38; // 37.5 del GDD, redondeado
  static const int bombardeoAncho = 3;
  static const int bombardeoLargo = 4;
  // Casilla en llamas → turnos que le quedan (cuentan los turnos de su dueño)
  final Map<int, int> fuegos = {};
  final Map<int, int> fuegoDueno = {}; // casilla → jugador que la incendió
  // Bengalas activas (3x3 que anula los muros de sacos enemigos)
  final List<Bengala> bengalas = [];

  // Habilidades del Sembrador
  static const int costoMina = 2;
  static const int costoLapa = 2;
  static const int costoCampo = 4;
  static const int rangoCampo = 4;
  static const int maxMinasPresion = 2; // por jugador, a la vez
  static const int danoMinaPresion = 50;
  static const bool minaIgnoraArmor = false; // el GDD dice "daño directo"
  static const int danoMinaFragmentacion = 40;
  static const int minasCampo = 3;
  static const int danoLapa = 45;
  static const double armorLapaIgnorado = 0.5;
  static const int armorPasivaSembrador = 10;
  final Map<int, Mina> minas = {}; // casilla → mina
  final Map<int, Lapa> lapas = {}; // id del tanque con la bomba pegada → bomba
  final Set<int> _sembradoresBlindados = {}; // ya tienen el +10 de Armor

  /// Semilla del azar (obstáculos y campo minado). Con la misma semilla y los
  /// mismos comandos, la partida se repite exactamente igual.
  final int semilla;
  final math.Random _azar;

  /// Comandos aplicados con éxito, en orden (sirve para repetir la partida).
  final List<Comando> historial = [];

  EstadoJuego({int? semilla})
      : this._(semilla ?? DateTime.now().millisecondsSinceEpoch);
  EstadoJuego._(int s)
      : semilla = s,
        _azar = math.Random(s);

  // Habilidades del Soporte
  static const int costoReparacion = 2;
  static const int costoCable = 2;
  static const int costoEstacion = 4;
  static const int costoUltimate = 4; // las ultimates no reciben descuento
  static const int curacionReparacion = 30;
  static const double armorReparacionPct = 0.10; // del Armor máximo del aliado
  static const int rangoCable = 2;
  static const int armorPasivaSoporte = 10;
  static const int curacionEstacion = 30;
  static const int armorEstacion = 15;
  static const int descuentoEstacion = 1;
  // Turnos del dueño que dura la Estación, contando el turno en que se crea
  // (igual que la Bengala y el Sacrificio). Con 3 curaría dos veces.
  static const int turnosEstacion = 2;
  static const List<List<int>> _vecinos8 = [
    [1, 0],
    [-1, 0],
    [0, 1],
    [0, -1],
    [1, 1],
    [1, -1],
    [-1, 1],
    [-1, -1],
  ];
  final List<Estacion> estaciones = [];
  // Tanques que empezaron su turno dentro de una Estación (-1 EN a sus habilidades)
  final Set<int> conDescuento = {};

  // ---------- Estados de los tanques ----------
  // Tanque (por id) → estados que tiene ahora mismo.
  final Map<int, Set<EstadoTanque>> estados = {};

  // Aviso de lo que pasó al terminar el turno (por ejemplo, reparaciones)
  String ultimoEvento = '';
  int _siguienteId = 1;

  void _evento(String texto) {
    ultimoEvento = ultimoEvento.isEmpty ? texto : '$ultimoEvento\n$texto';
  }

  static int idx(int col, int fila) => fila * columnas + col;

  /// Forma de alcance (movimiento y ataque): cuadrado sin esquinas.
  /// Con valor [n] llega hasta n casillas en cada eje, pero la diagonal
  /// llega una menos (n=3 → 7x7 sin esquinas; n=2 → 5x5 sin esquinas).
  static bool enForma(int dx, int dy, int n) {
    final ax = dx.abs();
    final ay = dy.abs();
    return ax <= n && ay <= n && ax + ay <= n + 1;
  }

  static int distancia(int c0, int f0, int c1, int f1) =>
      (c0 - c1).abs() + (f0 - f1).abs();

  // ---------- Consultas ----------

  bool enZona(int jugador, int fila) => jugador == 1
      ? fila >= filas - filasDespliegue
      : fila < filasDespliegue;

  Tanque? tanqueEn(int col, int fila) {
    for (final t in tanques) {
      if (t.col == col && t.fila == fila) return t;
    }
    return null;
  }

  Tanque? tanquePorId(int id) {
    for (final t in tanques) {
      if (t.id == id) return t;
    }
    return null;
  }

  Obstaculo? obstaculoEn(int col, int fila) {
    for (final o in obstaculos) {
      if (o.col == col && o.fila == fila) return o;
    }
    return null;
  }

  bool _esMuro(int col, int fila) {
    final o = obstaculoEn(col, fila);
    return o != null && o.tipo.esMuro;
  }

  int contar(int jugador) => tanques.where((t) => t.jugador == jugador).length;

  bool estaEnRampa(Tanque t) =>
      obstaculoEn(t.col, t.fila)?.tipo == TipoObstaculo.rampa;

  // ---------- Despliegue y turnos ----------

  bool colocarTanque(ClaseTanque clase, int col, int fila) {
    if (fase != Fase.despliegue) return false;
    if (!enZona(jugador, fila)) return false;
    if (contar(jugador) >= tanquesPorJugador) return false;
    if (tanqueEn(col, fila) != null) return false;
    tanques.add(Tanque(
      id: _siguienteId++,
      clase: clase,
      jugador: jugador,
      col: col,
      fila: fila,
    ));
    return true;
  }

  void quitarTanque(Tanque t) => tanques.remove(t);

  void confirmarDespliegue() {
    if (jugador == 1) {
      jugador = 2;
    } else {
      fase = Fase.juego;
      jugador = 1;
      movidos.clear();
      dispararon.clear();
      movidosTurno.clear();
      _nuevoTurnoFichas();
      generarObstaculos();
      _generarEnergiaBase();
    }
  }

  void terminarTurno() {
    ultimoEvento = '';
    // Los que no se movieron en este turno darán +1 EN temporal en el próximo turno suyo
    quietos[jugador] = {
      for (final t in tanques)
        if (t.jugador == jugador && !movidosTurno.contains(t.id)) t.id,
    };
    _resolverZonas();
    _repararMuros();
    _avanzarRuinas();
    _avanzarFuegosYBengalas();
    _avanzarEstaciones();
    _limpiarEstadosDelTurno();
    jugador = jugador == 1 ? 2 : 1;
    conDescuento.clear();
    movidos.clear();
    dispararon.clear();
    movidosTurno.clear();
    _aplicarFuego(); // antes de contar fichas: un tanque quemado puede morir
    _detonarLapas();
    _nuevoTurnoFichas();
    energiaTemporal = 0; // la energía temporal expira al terminar el turno
    escapePendiente = null;
    _quitarTrincheras();
    _aplicarPasivaSoporte();
    _aplicarEstaciones();
    _generarEnergiaBase();
    _generarEnergiaQuieta();
    _sincronizarPasivaSembrador();
  }

  void reiniciar() {
    fase = Fase.despliegue;
    jugador = 1;
    tanques.clear();
    obstaculos.clear();
    movidos.clear();
    dispararon.clear();
    movidosTurno.clear();
    fichaPropiaUsada.clear();
    ciclosAbiertos.clear();
    reservaTotal = 0;
    reservaUsada = 0;
    ganador = null;
    energia[1] = 0;
    energia[2] = 0;
    energiaTemporal = 0;
    quietos[1] = {};
    quietos[2] = {};
    trincherados.clear();
    zonaTurnos.clear();
    zonaAcumulado.clear();
    escapePendiente = null;
    duenos.clear();
    ruinas.clear();
    estados.clear();
    fuegos.clear();
    fuegoDueno.clear();
    bengalas.clear();
    historial.clear();
    estaciones.clear();
    conDescuento.clear();
    minas.clear();
    lapas.clear();
    _sembradoresBlindados.clear();
    ultimoEvento = '';
    _siguienteId = 1;
  }

  // ---------- Obstáculos ----------

  /// Se generan al azar en las filas del medio, siempre en parejas simétricas
  /// (giradas 180°) para que el mapa sea justo para los dos jugadores.
  void generarObstaculos([math.Random? azar]) {
    final r = azar ?? _azar;
    obstaculos.clear();
    duenos.clear();
    ruinas.clear();

    final libres = <int>[];
    for (int f = filasDespliegue; f < filas - filasDespliegue; f++) {
      for (int c = 0; c < columnas; c++) {
        libres.add(idx(c, f));
      }
    }
    libres.shuffle(r);

    final usados = <int>{};

    void poner(TipoObstaculo tipo, int parejas) {
      var puestas = 0;
      for (final k in libres) {
        if (puestas >= parejas) break;
        final c = k % columnas;
        final f = k ~/ columnas;
        final ce = columnas - 1 - c;
        final fe = filas - 1 - f;
        final ke = idx(ce, fe);
        if (usados.contains(k) || usados.contains(ke)) continue;
        usados.add(k);
        obstaculos.add(Obstaculo(tipo: tipo, col: c, fila: f));
        if (ke != k) {
          usados.add(ke);
          obstaculos.add(Obstaculo(tipo: tipo, col: ce, fila: fe));
        }
        puestas++;
      }
    }

    poner(TipoObstaculo.sacos, 2);
    poner(TipoObstaculo.ladrillo, 1);
    poner(TipoObstaculo.tinta, 1);
    poner(TipoObstaculo.cafe, 1);
    poner(TipoObstaculo.rampa, 1);
  }

  // ---------- Estados ----------

  bool tieneEstado(Tanque t, EstadoTanque e) =>
      estados[t.id]?.contains(e) ?? false;

  Set<EstadoTanque> estadosDe(Tanque t) => estados[t.id] ?? <EstadoTanque>{};

  bool estaAtascado(Tanque t) => tieneEstado(t, EstadoTanque.atascado);

  void aplicarEstado(Tanque t, EstadoTanque e) {
    (estados[t.id] ??= <EstadoTanque>{}).add(e);
  }

  void quitarEstado(Tanque t, EstadoTanque e) {
    final s = estados[t.id];
    if (s == null) return;
    s.remove(e);
    if (s.isEmpty) estados.remove(t.id);
  }

  /// Quita todos los estados negativos (Operación Trinchera, Estación de
  /// Reabastecimiento).
  void limpiarEstadosNegativos(Tanque t) {
    final s = estados[t.id];
    if (s == null) return;
    s.removeWhere((e) => e.negativo);
    if (s.isEmpty) estados.remove(t.id);
  }

  /// Hay que llamarla cada vez que un tanque termina en una casilla nueva
  /// (por moverse o porque lo empujan). Si es una mancha de tinta, queda
  /// Atascado. El Ligero la ignora. Devuelve true si lo atascó.
  bool _alLlegarACasilla(Tanque t) {
    final o = obstaculoEn(t.col, t.fila);
    if (o == null || !o.tipo.atasca || t.clase == ClaseTanque.ligero) {
      return false;
    }
    if (estaAtascado(t)) return false;
    aplicarEstado(t, EstadoTanque.atascado);
    return true;
  }

  /// Atascado dura hasta que termina el turno de su dueño: si el tanque
  /// entró en la tinta caminando pierde el resto de su movimiento, y si lo
  /// empujaron ahí no podrá moverse en su próximo turno.
  void _limpiarEstadosDelTurno() {
    for (final t in tanques) {
      if (t.jugador == jugador) quitarEstado(t, EstadoTanque.atascado);
    }
  }

  // ---------- Movimiento ----------

  /// Pasos de movimiento. El Ligero sobre una rampa sube a 4 (su pasiva).
  int movimientoEfectivo(Tanque t) {
    if (t.clase == ClaseTanque.ligero && estaEnRampa(t)) return 4;
    return t.clase.movimiento;
  }

  /// Casillas a las que puede llegar: pasos en cruz, sin atravesar tanques ni muros.
  /// Una mancha deja entrar pero corta el resto del movimiento (el Ligero la ignora).
  Set<int> alcanzables(Tanque t) {
    final resultado = <int>{};
    // Regla de oro, atrincherado y Fichas de Acción
    if (!puedeMover(t)) return resultado;
    final dist = <int, int>{idx(t.col, t.fila): 0};
    final cola = <List<int>>[
      [t.col, t.fila],
    ];
    final limite = movimientoEfectivo(t);
    var i = 0;
    while (i < cola.length) {
      final actual = cola[i++];
      final d = dist[idx(actual[0], actual[1])]!;
      if (d >= limite) continue;

      // Si está parado en una mancha (y no es Ligero), no sigue avanzando
      final aqui = obstaculoEn(actual[0], actual[1]);
      final atascadoAqui = aqui != null &&
          aqui.tipo.atasca &&
          t.clase != ClaseTanque.ligero &&
          !(actual[0] == t.col && actual[1] == t.fila);
      if (atascadoAqui) continue;

      for (final dir in const [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
        [1, 1],
        [1, -1],
        [-1, 1],
        [-1, -1],
      ]) {
        final c = actual[0] + dir[0];
        final f = actual[1] + dir[1];
        if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
        final k = idx(c, f);
        if (dist.containsKey(k)) continue;
        if (tanqueEn(c, f) != null) continue;
        if (_esMuro(c, f)) continue;
        dist[k] = d + 1;
        if (enForma(c - t.col, f - t.fila, limite)) resultado.add(k);
        cola.add([c, f]);
      }
    }
    return resultado;
  }

  /// Mueve el tanque. Devuelve un aviso si pasó algo (por ejemplo, Atascado).
  String? mover(Tanque t, int col, int fila) {
    if (!puedeMover(t)) return null;
    _usarCicloParaMover(t);
    t.col = col;
    t.fila = fila;
    _marcarMovido(t);
    final tinta = _alLlegarACasilla(t)
        ? '${t.clase.nombre} cayó en la tinta: Atascado (no puede moverse más este turno)'
        : null;
    final mina = _pisarMina(t);
    if (tinta == null) return mina;
    return mina == null ? tinta : '$tinta\n$mina';
  }

  // ---------- Ataque: rango y línea de visión ----------

  /// El disparo normal gana +1 de rango sobre una rampa.
  /// Las habilidades con alcance fijo no se benefician del bonus.
  int rangoEfectivo(Tanque t) => t.clase.rango + (estaEnRampa(t) ? 1 : 0);

  /// Solo los muros bloquean la visión. Se traza una línea entre los centros
  /// de las dos casillas; las casillas de los extremos no cuentan.
  bool hayVision(int c0, int f0, int c1, int f1) {
    var x = c0;
    var y = f0;
    final dx = (c1 - c0).abs();
    final dy = (f1 - f0).abs();
    final sx = c0 < c1 ? 1 : -1;
    final sy = f0 < f1 ? 1 : -1;
    var err = dx - dy;
    while (true) {
      if (x == c1 && y == f1) return true;
      final e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x += sx;
      }
      if (e2 < dx) {
        err += dx;
        y += sy;
      }
      if (x == c1 && y == f1) return true;
      if (_muroEfectivo(x, y)) return false;
    }
  }

  RangoAtaque rangoDe(Tanque t) {
    final base = t.clase.rango;
    final total = rangoEfectivo(t);
    final alcance = <int>{};
    final visibles = <int>{};
    final objetivos = <int>{};
    final bonus = <int>{};

    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, total)) continue;
        final k = idx(c, f);
        alcance.add(k);
        if (!enForma(dx, dy, base)) bonus.add(k);
        if (!hayVision(t.col, t.fila, c, f)) continue;
        visibles.add(k);
        final otro = tanqueEn(c, f);
        final obs = obstaculoEn(c, f);
        final esEnemigo = otro != null && otro.jugador != t.jugador;
        final esMuro = obs != null && obs.tipo.esMuro;
        if (esEnemigo || esMuro) objetivos.add(k);
      }
    }

    return RangoAtaque(
      origen: idx(t.col, t.fila),
      alcance: alcance,
      visibles: visibles,
      objetivos: objetivos,
      bonus: bonus,
    );
  }

  // ---------- Sistema Relevo de Acción ----------

  /// Al empezar el turno de un jugador: cada tanque vivo tiene su ficha y la ficha
  /// de cada tanque destruido pasa a la reserva común (hasta completar 3 en total).
  void _nuevoTurnoFichas() {
    fichaPropiaUsada.clear();
    ciclosAbiertos.clear();
    reservaUsada = 0;
    reservaTotal = math.max(0, tanquesPorJugador - contar(jugador));
  }

  int get fichasPropiasLibres => tanques
      .where((t) => t.jugador == jugador && !fichaPropiaUsada.contains(t.id))
      .length;
  int get fichasReservaLibres => reservaTotal - reservaUsada;
  int get fichasRestantes => fichasPropiasLibres + fichasReservaLibres;
  int get fichasTotales => contar(jugador) + reservaTotal;

  /// ¿Puede el tanque abrir un ciclo nuevo? Usa su ficha propia o una de la reserva.
  bool puedeAbrirCiclo(Tanque t) =>
      !fichaPropiaUsada.contains(t.id) || reservaUsada < reservaTotal;

  bool _cicloLibreParaMover(Tanque t) =>
      ciclosAbiertos.contains(t.id) &&
      !movidos.contains(t.id) &&
      !dispararon.contains(t.id);

  bool _cicloLibreParaDisparar(Tanque t) =>
      ciclosAbiertos.contains(t.id) && !dispararon.contains(t.id);

  /// Gasta una ficha y empieza un ciclo limpio (mover + disparar) para el tanque.
  void _abrirCiclo(Tanque t) {
    if (!fichaPropiaUsada.contains(t.id)) {
      fichaPropiaUsada.add(t.id);
    } else {
      reservaUsada++;
    }
    ciclosAbiertos.add(t.id);
    movidos.remove(t.id);
    dispararon.remove(t.id);
    if (escapePendiente == t.id) escapePendiente = null;
  }

  void _usarCicloParaMover(Tanque t) {
    if (!_cicloLibreParaMover(t)) _abrirCiclo(t);
  }

  void _usarCicloParaDisparar(Tanque t) {
    if (!_cicloLibreParaDisparar(t)) _abrirCiclo(t);
  }

  void _marcarMovido(Tanque t) {
    movidos.add(t.id);
    movidosTurno.add(t.id);
  }

  /// Puede moverse: es su turno, no está atrincherado y le queda un ciclo
  /// libre (o una ficha para abrir uno nuevo).
  bool puedeMover(Tanque t) =>
      _esSuTurno(t) &&
      !trincherados.contains(t.id) &&
      !estaAtascado(t) &&
      (_cicloLibreParaMover(t) || puedeAbrirCiclo(t));

  /// El tanque ya no puede hacer nada más en este turno.
  bool sinAcciones(Tanque t) =>
      fase == Fase.juego &&
      t.jugador == jugador &&
      !puedeMover(t) &&
      !puedeDisparar(t);

  // ---------- Energía ----------

  /// Al inicio del turno: 1 EN por tanque vivo (máximo 3).
  void _generarEnergiaBase() {
    energia[jugador] = energia[jugador]! + math.min(contar(jugador), 3);
  }

  /// Energía Volátil: +1 EN temporal por cada tanque que se quedó quieto
  /// en su turno anterior (Soporte: +2), haya atacado o no. Máximo 5.
  void _generarEnergiaQuieta() {
    var extra = 0;
    for (final t in tanques) {
      if (t.jugador == jugador && quietos[jugador]!.contains(t.id)) {
        extra += t.clase == ClaseTanque.soporte ? 2 : 1;
      }
    }
    energiaTemporal = math.min(extra, maxEnergiaTemporal);
  }

  int get energiaDisponible => energia[jugador]! + energiaTemporal;

  /// Se gasta primero la temporal (que expira) y después la guardada.
  void _gastarEnergia(int costo, [Tanque? t]) {
    final c = t == null ? costo : costoEfectivo(t, costo);
    final deTemporal = math.min(energiaTemporal, c);
    energiaTemporal -= deTemporal;
    energia[jugador] = energia[jugador]! - (c - deTemporal);
  }

  /// Costo real de una habilidad: si el tanque empezó su turno en una Estación
  /// de Reabastecimiento paga 1 EN menos (mínimo 1). Las ultimates no cuentan.
  int costoEfectivo(Tanque t, int costo) {
    if (!conDescuento.contains(t.id) || costo >= costoUltimate) return costo;
    return math.max(1, costo - descuentoEstacion);
  }

  // ---------- Disparo básico ----------

  int _conRampa(Tanque t, int base) =>
      estaEnRampa(t) ? (base * 1.25).round() : base;

  /// Daño del disparo básico. La rampa da +25% de daño.
  int danoDisparo(Tanque t) => _conRampa(t, t.clase.dano);

  bool puedeDisparar(Tanque t) =>
      fase == Fase.juego &&
      ganador == null &&
      t.jugador == jugador &&
      (_cicloLibreParaDisparar(t) || puedeAbrirCiclo(t));

  bool puedePagarDisparo(Tanque t, [int? costo]) =>
      energiaDisponible >= costoEfectivo(t, costo ?? t.clase.costoTiro);

  /// El Armor es una capa sobre la vida: el daño le pega primero y,
  /// cuando se acaba, lo que sobra pasa a la vida.
  /// Devuelve [daño al armor, daño a la vida].
  /// [armorIgnorado] es la fracción del Armor que el golpe no puede usar
  /// (la pasiva del Artillero ignora el 20%).
  List<int> _danarTanque(Tanque o, int dano,
      {bool ignoraArmor = false, double armorIgnorado = 0, Tanque? atacante}) {
    var d = dano;
    var recortado = 0;
    // Pasiva del Pesado (Blindaje Compuesto): -20% al daño de frente, antes del Armor
    if (o.clase == ClaseTanque.pesado &&
        atacante != null &&
        _ataqueDeFrente(o, atacante)) {
      d = (d * 0.8).round();
      recortado = 1;
    }
    // Zona del Sacrificio del Comandante: los aliados dentro reciben 30% menos
    for (final id in zonaTurnos.keys) {
      final p = tanquePorId(id);
      if (p == null || p.jugador != o.jugador || p.id == o.id) continue;
      if ((o.col - p.col).abs() <= 2 && (o.fila - p.fila).abs() <= 2) {
        final nuevo = (d * 0.7).round();
        zonaAcumulado[id] = (zonaAcumulado[id] ?? 0) + (d - nuevo);
        d = nuevo;
        break;
      }
    }
    final armorUsable =
        ignoraArmor ? 0 : (o.armor * (1 - armorIgnorado)).round();
    final alArmor = math.min(armorUsable, d);
    o.armor -= alArmor;
    o.armorExtra = math.max(0, o.armorExtra - alArmor);
    final aLaVida = d - alArmor;
    o.vida -= aLaVida;
    return [alArmor, aLaVida, recortado];
  }

  /// El atacante está dentro del triángulo frontal, que se abre 3, 5, 7...
  /// casillas por fila y continúa hasta el borde del tablero.
  bool _ataqueDeFrente(Tanque defensor, Tanque atacante) {
    final dx = atacante.col - defensor.col;
    final dy = atacante.fila - defensor.fila;
    final k = dx * defensor.dirCol + dy * defensor.dirFila;
    final lado = (dx * defensor.dirFila - dy * defensor.dirCol).abs();
    return k >= 1 && lado <= k - 1;
  }

  /// Cono frontal con anchos de 1, 3, 5, 7... hasta el borde del tablero.
  Set<int> conoFrente(Tanque t) {
    final res = <int>{};
    final maxDepth = t.dirCol < 0
        ? t.col
        : t.dirCol > 0
            ? columnas - 1 - t.col
            : t.dirFila < 0
                ? t.fila
                : filas - 1 - t.fila;
    for (var k = 1; k <= maxDepth; k++) {
      for (var l = -(k - 1); l <= k - 1; l++) {
        final c = t.col + t.dirCol * k - t.dirFila * l;
        final f = t.fila + t.dirFila * k + t.dirCol * l;
        if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
        res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Gira el tanque en 8 direcciones (45° por paso): N, NE, E, SE, S, SW, W, NW.
  void girar(Tanque t) {
    if (!_esSuTurno(t)) return;
    const dirs = [
      [0, -1],
      [1, -1],
      [1, 0],
      [1, 1],
      [0, 1],
      [-1, 1],
      [-1, 0],
      [-1, -1],
    ];
    for (var i = 0; i < dirs.length; i++) {
      if (t.dirCol == dirs[i][0] && t.dirFila == dirs[i][1]) {
        final s = dirs[(i + 1) % dirs.length];
        t.dirCol = s[0];
        t.dirFila = s[1];
        return;
      }
    }
    // Si llegara una dirección rara, se normaliza a la primera del conjunto.
    t.dirCol = 0;
    t.dirFila = -1;
  }

  void _revisarVictoria(int atacante) {
    final rival = atacante == 1 ? 2 : 1;
    if (contar(rival) == 0) ganador = atacante;
  }

  /// Dispara a la casilla (col, fila). Devuelve el texto del resultado,
  /// o null si el disparo no es válido.
  String? disparar(Tanque t, int col, int fila,
      {int? costo,
      bool escape = false,
      bool ignoraArmor = false,
      int? danoBase}) {
    if (!puedeDisparar(t)) return null;
    if (!rangoDe(t).objetivos.contains(idx(col, fila))) return null;
    final c = costo ?? t.clase.costoTiro;
    if (!puedePagarDisparo(t, c)) return null;

    var dano = danoBase != null ? _conRampa(t, danoBase) : danoDisparo(t);
    // Pasiva del Artillero (Cálculo Balístico Extremo): bono por distancia
    // y, si estuvo quieto, ignora 20% del Armor
    final bonus = t.clase == ClaseTanque.artilleria
        ? bonusDistancia(_distanciaTiro(t, col, fila))
        : 0.0;
    if (bonus > 0) dano = (dano * (1 + bonus)).round();
    final pasiva = pasivaArtilleriaActiva(t);
    _usarCicloParaDisparar(t);
    _gastarEnergia(c, t);
    final perfora = ignoraArmor;
    dispararon.add(t.id);

    final enemigo = tanqueEn(col, fila);
    if (enemigo != null) {
      final r = _danarTanque(enemigo, dano,
          ignoraArmor: perfora,
          armorIgnorado: pasiva ? armorIgnoradoPasiva : 0,
          atacante: t);
      var texto = '${t.clase.nombre} hizo ${r[0] + r[1]} a '
          '${enemigo.clase.nombre} (Armor -${r[0]}, HP -${r[1]})';
      if (r[2] == 1) texto += ' · recortado 20% (de frente)';
      if (perfora) texto += ' · ignoró el Armor';
      if (bonus > 0) texto += ' · +${(bonus * 100).round()}% por distancia';
      if (pasiva && !perfora) texto += ' · ignoró 20% del Armor';
      if (enemigo.vida <= 0) {
        tanques.remove(enemigo);
        texto += ' · ¡destruido!';
        _revisarVictoria(t.jugador);
      }
      if (escape) _prepararEscape(t);
      return texto;
    }

    final muro = obstaculoEn(col, fila);
    if (muro != null && muro.tipo.esMuro) {
      // Pasiva del Zapador (Ingeniería de Campo): doble daño a los muros
      final danoMuro = t.clase == ClaseTanque.zapador ? dano * 2 : dano;
      muro.hp -= danoMuro;
      var texto = '${t.clase.nombre} hizo $danoMuro a ${muro.tipo.nombre}';
      if (muro.hp <= 0) {
        obstaculos.remove(muro);
        duenos.remove(muro);
        texto += ' · ¡destruido!';
      }
      if (escape) _prepararEscape(t);
      return texto;
    }

    return null;
  }

  // ---------- Habilidades del Ligero ----------

  /// Habilidad 3 · Maniobra de Escape: tras disparar, 1 casilla a los lados o atrás.
  /// "Adelante" es hacia el rival (J1 sube, J2 baja).
  Set<int> casillasEscape(Tanque t) {
    final adelante = t.jugador == 1 ? -1 : 1;
    final res = <int>{};
    for (final d in [
      [1, 0],
      [-1, 0],
      [0, -adelante],
    ]) {
      final c = t.col + d[0];
      final f = t.fila + d[1];
      if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
      if (tanqueEn(c, f) != null || _esMuro(c, f)) continue;
      res.add(idx(c, f));
    }
    return res;
  }

  void _prepararEscape(Tanque t) {
    escapePendiente = casillasEscape(t).isEmpty ? null : t.id;
  }

  String? completarEscape(Tanque t, int col, int fila) {
    if (escapePendiente != t.id) return null;
    if (!casillasEscape(t).contains(idx(col, fila))) return null;
    t.col = col;
    t.fila = fila;
    _marcarMovido(t);
    escapePendiente = null;
    final mina = _pisarMina(t);
    return '${t.clase.nombre} se reposicionó${mina != null ? '\n$mina' : ''}';
  }

  // ---------- Habilidades del Pesado ----------

  bool _esSuTurno(Tanque t) =>
      fase == Fase.juego && ganador == null && t.jugador == jugador;

  /// Habilidad 2 · Trinchera: +20 de Armor y sin ser empujado hasta su siguiente turno.
  /// Se atrinchera en su lugar, así que no se mueve mientras dure.
  String activarTrinchera(Tanque t) {
    if (t.clase != ClaseTanque.pesado || !_esSuTurno(t)) return 'No disponible';
    if (trincherados.contains(t.id)) return 'Ya está atrincherado';
    if (!puedePagarDisparo(t, costoTrinchera)) {
      return 'Energía insuficiente (cuesta $costoTrinchera EN)';
    }
    _gastarEnergia(costoTrinchera, t);
    trincherados.add(t.id);
    t.armor += 20;
    t.armorExtra += 20;
    return 'Atrincherado: +20 de Armor y no puede ser empujado hasta su siguiente turno';
  }

  /// Al empezar el turno de su dueño, la Trinchera termina y se pierde el Armor extra.
  void _quitarTrincheras() {
    for (final t in tanques) {
      if (t.jugador != jugador) continue;
      if (trincherados.remove(t.id)) {
        t.armor = math.max(0, t.armor - t.armorExtra);
        t.armorExtra = 0;
      }
    }
  }

  /// Habilidad 3 · Embestida de Oruga: casillas a 1 paso en cruz. Libre = avanza 1
  /// (y embiste al tanque que tenga justo enfrente); con enemigo = lo embiste
  /// y, si lo empuja, el Pesado avanza con él.
  Set<int> objetivosEmbestida(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.pesado || !puedeDisparar(t)) return res;
    for (final d in const [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ]) {
      final c = t.col + d[0];
      final f = t.fila + d[1];
      if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
      if (_esMuro(c, f)) continue;
      final o = tanqueEn(c, f);
      if (o == null) {
        if (!trincherados.contains(t.id)) res.add(idx(c, f));
      } else if (o.jugador != t.jugador) {
        res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Golpe de la embestida: 30 de daño y empuje de 1 casilla. Devuelve (texto, empujado).
  (String, bool) _embestirA(Tanque t, Tanque o, int dx, int dy) {
    final dano = _conRampa(t, 30);
    final r = _danarTanque(o, dano, atacante: t);
    var texto = 'Embestida: ${o.clase.nombre} -${r[0] + r[1]} '
        '(Armor -${r[0]}, HP -${r[1]})';
    if (r[2] == 1) texto += ' · recortado 20% (de frente)';

    if (o.vida <= 0) {
      tanques.remove(o);
      _revisarVictoria(t.jugador);
      return ('$texto · ¡destruido!', false);
    }
    if (trincherados.contains(o.id)) return ('$texto · inmune al empuje', false);

    final c = o.col + dx;
    final f = o.fila + dy;
    if (c >= 0 &&
        c < columnas &&
        f >= 0 &&
        f < filas &&
        tanqueEn(c, f) == null &&
        !_esMuro(c, f)) {
      o.col = c;
      o.fila = f;
      final atascado = _alLlegarACasilla(o);
      final mina = _pisarMina(o);
      return (
        '$texto · empujado${atascado ? ' a la tinta: ¡Atascado!' : ''}'
            '${mina != null ? '\n$mina' : ''}',
        true
      );
    }
    return ('$texto · no pudo ser empujado', false);
  }

  String? embestir(Tanque t, int col, int fila) {
    if (!objetivosEmbestida(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoEmbestida)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoEmbestida, t);
    dispararon.add(t.id);

    final dx = col - t.col;
    final dy = fila - t.fila;
    final enemigo = tanqueEn(col, fila);

    if (enemigo != null) {
      // Lo tiene a la par: lo embiste y, si lo empuja, se va con él
      final (texto, empujado) = _embestirA(t, enemigo, dx, dy);
      if (empujado && !trincherados.contains(t.id)) {
        t.col = col;
        t.fila = fila;
        _marcarMovido(t);
        final atascado = _alLlegarACasilla(t);
        final mina = _pisarMina(t);
        return '$texto${atascado ? ' · el Pesado quedó Atascado' : ''}'
            '${mina != null ? '\n$mina' : ''}';
      }
      return texto;
    }

    // Casilla libre: avanza 1 y embiste al que tenga justo enfrente
    t.col = col;
    t.fila = fila;
    _marcarMovido(t);
    final atascado = _alLlegarACasilla(t) ? ' · Atascado en la tinta' : '';
    final mina = _pisarMina(t);
    final avisoMina = mina != null ? '\n$mina' : '';
    if (!tanques.contains(t)) return 'Avanzó 1$avisoMina'; // murió en la mina
    final c2 = col + dx;
    final f2 = fila + dy;
    if (c2 >= 0 && c2 < columnas && f2 >= 0 && f2 < filas) {
      final o2 = tanqueEn(c2, f2);
      if (o2 != null && o2.jugador != t.jugador) {
        final (texto, _) = _embestirA(t, o2, dx, dy);
        return 'Avanzó 1$atascado$avisoMina · $texto';
      }
    }
    return 'Avanzó 1 casilla$atascado$avisoMina';
  }

  /// Ultimate · Sacrificio del Comandante: dispara 65 de daño (rango 3), recupera
  /// 20% de su Armor, gana +10 de Armor máximo y crea una zona de 5x5 a su alrededor
  /// por 3 turnos suyos donde los aliados reciben 30% menos de daño.
  /// Al final del tercero, el daño mitigado se le inflige directo al Pesado.
  String? sacrificio(Tanque t, int col, int fila) {
    if (t.clase != ClaseTanque.pesado || !puedeDisparar(t)) return null;
    if (zonaTurnos.containsKey(t.id)) return null;
    final res =
        disparar(t, col, fila, costo: costoSacrificio, danoBase: 65);
    if (res == null) return null;
    final cura = (t.armor * 0.2).round();
    t.armor += cura;
    t.armorBono += 10;
    zonaTurnos[t.id] = 3;
    zonaAcumulado[t.id] = 0;
    return '$res · Armor +$cura, Armor máx +10 · zona activa';
  }

  /// Al terminar un turno: avanza el contador de las zonas de ese jugador y,
  /// si se acaban, el daño mitigado golpea directo a la vida del Pesado.
  void _resolverZonas() {
    for (final id in zonaTurnos.keys.toList()) {
      final p = tanquePorId(id);
      if (p == null) {
        zonaTurnos.remove(id);
        zonaAcumulado.remove(id);
        continue;
      }
      if (p.jugador != jugador) continue;
      final quedan = zonaTurnos[id]! - 1;
      if (quedan > 0) {
        zonaTurnos[id] = quedan;
        continue;
      }
      final dano = zonaAcumulado[id] ?? 0;
      zonaTurnos.remove(id);
      zonaAcumulado.remove(id);
      p.vida -= dano;
      if (p.vida <= 0) {
        tanques.remove(p);
        _revisarVictoria(p.jugador == 1 ? 2 : 1);
      }
    }
  }

  /// Ultimate · Ráfaga en Carrera: 4 pasos en cruz (sin diagonales) que rodean
  /// tanques y muros. Devuelve, para cada destino posible, el camino casilla a casilla.
  Map<int, List<int>> _caminosRafaga(Tanque t) {
    final origen = idx(t.col, t.fila);
    final padre = <int, int>{};
    final dist = <int, int>{origen: 0};
    final cola = <int>[origen];
    var i = 0;
    while (i < cola.length) {
      final k = cola[i++];
      final d = dist[k]!;
      if (d >= 4) continue;
      final c0 = k % columnas;
      final f0 = k ~/ columnas;
      for (final dir in const [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
      ]) {
        final c = c0 + dir[0];
        final f = f0 + dir[1];
        if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
        final k2 = idx(c, f);
        if (dist.containsKey(k2)) continue;
        if (tanqueEn(c, f) != null || _esMuro(c, f)) continue;
        dist[k2] = d + 1;
        padre[k2] = k;
        cola.add(k2);
      }
    }
    final caminos = <int, List<int>>{};
    for (final destino in padre.keys) {
      final ruta = <int>[];
      var actual = destino;
      while (actual != origen) {
        ruta.add(actual);
        actual = padre[actual]!;
      }
      caminos[destino] = ruta.reversed.toList();
    }
    return caminos;
  }

  Set<int> destinosRafaga(Tanque t) {
    if (t.clase != ClaseTanque.ligero || !puedeDisparar(t)) return <int>{};
    return _caminosRafaga(t).keys.toSet();
  }

  Tanque? _enemigoMasCercano(Tanque t) {
    final rango = rangoEfectivo(t);
    Tanque? mejor;
    var mejorD = 1 << 30;
    for (final o in tanques) {
      if (o.jugador == t.jugador) continue;
      final d = distancia(t.col, t.fila, o.col, o.fila);
      if (!enForma(o.col - t.col, o.fila - t.fila, rango) || d >= mejorD) {
        continue;
      }
      if (!hayVision(t.col, t.fila, o.col, o.fila)) continue;
      mejor = o;
      mejorD = d;
    }
    return mejor;
  }

  String? rafaga(Tanque t, int col, int fila) {
    if (t.clase != ClaseTanque.ligero || !puedeDisparar(t)) return null;
    final ruta = _caminosRafaga(t)[idx(col, fila)];
    if (ruta == null) return null;
    if (!puedePagarDisparo(t, costoRafaga)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoRafaga, t);

    final golpes = <String>[];
    for (final k in ruta) {
      t.col = k % columnas;
      t.fila = k ~/ columnas;
      final mina = _pisarMina(t);
      if (mina != null) {
        golpes.add(mina);
        // Muerto o Atascado: la ráfaga se corta aquí
        if (!tanques.contains(t) || estaAtascado(t)) break;
      }
      final obj = _enemigoMasCercano(t);
      if (obj == null) continue;
      final dano = _conRampa(t, 20);
      final r = _danarTanque(obj, dano, atacante: t);
      var s = '${obj.clase.nombre} -${r[0] + r[1]}';
      if (obj.vida <= 0) {
        tanques.remove(obj);
        s += ' (destruido)';
      }
      golpes.add(s);
    }

    _marcarMovido(t);
    dispararon.add(t.id);
    _revisarVictoria(t.jugador);
    return golpes.isEmpty
        ? 'Ráfaga sin objetivos'
        : 'Ráfaga: ${golpes.join(', ')}';
  }

  // ---------- Habilidades del Zapador ----------

  bool _libreParaMuro(int col, int fila) {
    if (col < 0 || col >= columnas || fila < 0 || fila >= filas) return false;
    if (tanqueEn(col, fila) != null) return false;
    if (obstaculoEn(col, fila) != null) return false;
    if (ruinas.containsKey(idx(col, fila))) return false; // casilla arruinada
    return true;
  }

  /// Los muros del mapa son neutrales; los que se construyen son del equipo.
  Obstaculo _ponerMuro(int jugadorDueno, int col, int fila) {
    final o = Obstaculo(tipo: TipoObstaculo.sacos, col: col, fila: fila);
    obstaculos.add(o);
    duenos[o] = jugadorDueno;
    return o;
  }

  /// A cubierto: tiene un muro (de cualquier dueño) en alguna de las 8 casillas vecinas.
  bool _aCubierto(Tanque a) {
    for (var dc = -1; dc <= 1; dc++) {
      for (var df = -1; df <= 1; df++) {
        if (dc == 0 && df == 0) continue;
        if (_muroEfectivo(a.col + dc, a.fila + df)) return true;
      }
    }
    return false;
  }

  /// Pasiva · Ingeniería de Campo: al terminar su turno, cada Zapador repara +15 HP
  /// los muros de su equipo que tenga en las 8 casillas vecinas.
  void _repararMuros() {
    var reparados = 0;
    final vistos = <Obstaculo>{};
    for (final z in tanques) {
      if (z.jugador != jugador || z.clase != ClaseTanque.zapador) continue;
      for (var dc = -1; dc <= 1; dc++) {
        for (var df = -1; df <= 1; df++) {
          if (dc == 0 && df == 0) continue;
          final o = obstaculoEn(z.col + dc, z.fila + df);
          if (o == null || !o.tipo.esMuro) continue;
          if (duenos[o] != jugador) continue;
          if (o.hp >= Obstaculo.hpMuro) continue;
          if (!vistos.add(o)) continue;
          o.hp = math.min(Obstaculo.hpMuro, o.hp + curacionMuro);
          reparados++;
        }
      }
    }
    if (reparados > 0) {
      _evento('Zapador reparó $reparados muro(s) (+$curacionMuro HP)');
    }
  }

  /// Las casillas arruinadas duran el resto del turno y el turno completo del rival.
  void _avanzarRuinas() {
    for (final k in ruinas.keys.toList()) {
      final quedan = ruinas[k]! - 1;
      if (quedan <= 0) {
        ruinas.remove(k);
      } else {
        ruinas[k] = quedan;
      }
    }
  }

  /// Habilidad 2 · Despliegue de Sacos de Arena: casillas libres entre sus 8 vecinas.
  Set<int> casillasSacos(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.zapador || !puedeDisparar(t)) return res;
    for (var dc = -1; dc <= 1; dc++) {
      for (var df = -1; df <= 1; df++) {
        if (dc == 0 && df == 0) continue;
        final c = t.col + dc;
        final f = t.fila + df;
        if (_libreParaMuro(c, f)) res.add(idx(c, f));
      }
    }
    return res;
  }

  String? construirSacos(Tanque t, int col, int fila) {
    if (!casillasSacos(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoSacos)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoSacos, t);
    dispararon.add(t.id);
    _ponerMuro(t.jugador, col, fila);
    return 'Zapador levantó un muro de sacos de arena (${Obstaculo.hpMuro} HP)';
  }

  /// Muros que hay justo entre dos casillas (sin contar los extremos).
  List<int> _murosEnLinea(int c0, int f0, int c1, int f1) {
    final res = <int>[];
    var x = c0;
    var y = f0;
    final dx = (c1 - c0).abs();
    final dy = (f1 - f0).abs();
    final sx = c0 < c1 ? 1 : -1;
    final sy = f0 < f1 ? 1 : -1;
    var err = dx - dy;
    while (true) {
      if (x == c1 && y == f1) return res;
      final e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x += sx;
      }
      if (e2 < dx) {
        err += dx;
        y += sy;
      }
      if (x == c1 && y == f1) return res;
      if (_muroEfectivo(x, y)) res.add(idx(x, y));
    }
  }

  /// Habilidad 3 · Rompemuros: enemigos en rango cuya visión tapa, como mucho, un muro.
  Set<int> objetivosRompemuros(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.zapador || !puedeDisparar(t)) return res;
    final r = rangoEfectivo(t);
    for (final o in tanques) {
      if (o.jugador == t.jugador) continue;
      if (!enForma(o.col - t.col, o.fila - t.fila, r)) continue;
      if (_murosEnLinea(t.col, t.fila, o.col, o.fila).length > 1) continue;
      res.add(idx(o.col, o.fila));
    }
    return res;
  }

  /// 45 de daño. Si el enemigo se cubría detrás de un muro, lo destruye al instante,
  /// ignora el Armor y la casilla queda arruinada (nadie construye ni repara ahí).
  String? rompemuros(Tanque t, int col, int fila) {
    if (!objetivosRompemuros(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoRompemuros)) return null;
    final enemigo = tanqueEn(col, fila);
    if (enemigo == null) return null;
    final muros = _murosEnLinea(t.col, t.fila, col, fila);
    final tapado = muros.isNotEmpty;

    _usarCicloParaDisparar(t);
    _gastarEnergia(costoRompemuros, t);
    dispararon.add(t.id);

    var extra = '';
    if (tapado) {
      final k = muros.first;
      final muro = obstaculoEn(k % columnas, k ~/ columnas);
      if (muro != null) {
        obstaculos.remove(muro);
        duenos.remove(muro);
      }
      ruinas[k] = 2;
      extra = ' · muro destruido, ignoró el Armor';
    }

    final r = _danarTanque(enemigo, _conRampa(t, 45),
        ignoraArmor: tapado, atacante: t);
    var texto = 'Rompemuros: ${enemigo.clase.nombre} -${r[0] + r[1]} '
        '(Armor -${r[0]}, HP -${r[1]})$extra';
    if (r[2] == 1) texto += ' · recortado 20% (de frente)';
    if (enemigo.vida <= 0) {
      tanques.remove(enemigo);
      texto += ' · ¡destruido!';
      _revisarVictoria(t.jugador);
    }
    return texto;
  }

  /// Ultimate · Operación Trinchera: casillas libres dentro de su rango.
  Set<int> casillasOperacion(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.zapador || !puedeDisparar(t)) return res;
    final r = rangoEfectivo(t);
    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, r)) continue;
        if (_libreParaMuro(c, f)) res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Pone dos muros de golpe. Los aliados a cubierto ganan +20 de Armor y se limpian
  /// de estados negativos (cuando existan estados como fuego o anclaje).
  String? operacionTrinchera(Tanque t, List<int> celdas) {
    if (celdas.length != 2 || celdas[0] == celdas[1]) return null;
    final validas = casillasOperacion(t);
    if (!celdas.every(validas.contains)) return null;
    if (!puedePagarDisparo(t, costoOperacion)) return null;

    _usarCicloParaDisparar(t);
    _gastarEnergia(costoOperacion, t);
    dispararon.add(t.id);

    for (final k in celdas) {
      _ponerMuro(t.jugador, k % columnas, k ~/ columnas);
    }
    var cubiertos = 0;
    for (final a in tanques) {
      if (a.jugador != t.jugador || !_aCubierto(a)) continue;
      a.armor += 20;
      limpiarEstadosNegativos(a); // Atascado, humo, anclaje...
      cubiertos++;
    }
    return 'Operación Trinchera: 2 muros · $cubiertos aliado(s) a cubierto '
        'ganan +20 de Armor y se limpian de estados negativos';
  }

  // ---------- Artillero ----------

  /// Distancia del tiro con la misma forma que el rango (cuadrado sin esquinas).
  int _distanciaTiro(Tanque t, int col, int fila) =>
      math.max((col - t.col).abs(), (fila - t.fila).abs());

  /// La rampa da +1 de rango a todo lo del Artillero.
  /// Alcance fijo de las habilidades del Artillero: no aumenta sobre rampa.
  int _rangoArtillero(Tanque t, int base) => base;

  /// Pasiva · Cálculo Balístico Extremo (parte 1): no se movió ni en este
  /// turno ni en el anterior → sus ataques ignoran 20% del Armor enemigo.
  bool pasivaArtilleriaActiva(Tanque t) =>
      t.clase == ClaseTanque.artilleria &&
      !movidosTurno.contains(t.id) &&
      (quietos[t.jugador]?.contains(t.id) ?? false);

  /// Pasiva (parte 2): bono de daño por distancia. +10% a 3 casillas, +15% a 4,
  /// +20% a 5 y +5% por cada casilla más (las que dan los Módulos de Refuerzo).
  double bonusDistancia(int d) {
    if (d < 3) return 0;
    if (d == 3) return 0.10;
    if (d == 4) return 0.15;
    return 0.20 + 0.05 * (d - 5);
  }

  // Habilidad 1 · Fuego de Obús Pesado (2 EN, rango 5, 75 de daño): es el
  // disparo básico del Artillero (botón Atacar), con la pasiva aplicada
  // dentro de [disparar]. Para que llegue a rango 5, ClaseTanque.artilleria
  // debe tener rango: 5.

  /// Habilidad 2 · Disparo de Iluminación: centro del 3x3, a rango 6.
  Set<int> casillasBengala(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.artilleria || !puedeDisparar(t)) return res;
    final r = _rangoArtillero(t, rangoBengala);
    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, r)) continue;
        res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Sin daño. Durante 2 turnos del Artillero, los muros de sacos del rival
  /// dentro del 3x3 no dan cobertura ni tapan la visión, y los enemigos
  /// expuestos (los que están dentro del 3x3) pierden 20 de Armor.
  String? lanzarBengala(Tanque t, int col, int fila) {
    if (!casillasBengala(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoBengala)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoBengala, t);
    dispararon.add(t.id);

    bengalas.add(Bengala(
      col: col,
      fila: fila,
      jugador: t.jugador,
      turnos: turnosBengala,
    ));

    var expuestos = 0;
    for (final o in tanques) {
      if (o.jugador == t.jugador) continue;
      if ((o.col - col).abs() > 1 || (o.fila - fila).abs() > 1) continue;
      final quita = math.min(o.armor, armorBengala);
      o.armor -= quita;
      o.armorExtra = math.max(0, o.armorExtra - quita);
      expuestos++;
    }
    return 'Bengala: los muros de sacos enemigos del 3x3 quedan anulados '
        '$turnosBengala turnos · $expuestos enemigo(s) expuesto(s) '
        '(-$armorBengala Armor)';
  }

  /// Habilidad 3 · Munición Incendiaria: cualquier casilla con visión a
  /// rango 5 que no tenga un aliado (también sirve para negar una zona).
  Set<int> casillasIncendiaria(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.artilleria || !puedeDisparar(t)) return res;
    for (final k in rangoDe(t).visibles) {
      final otro = tanqueEn(k % columnas, k ~/ columnas);
      if (otro != null && otro.jugador == t.jugador) continue;
      res.add(k);
    }
    return res;
  }

  /// 40 de daño de impacto (con la pasiva) e inflama la casilla 3 turnos.
  /// Al empezar su turno, un enemigo parado ahí recibe 20 directo a la vida.
  String? incendiaria(Tanque t, int col, int fila) {
    if (!casillasIncendiaria(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoIncendiaria)) return null;

    String texto;
    final hayBlanco = rangoDe(t).objetivos.contains(idx(col, fila));
    if (hayBlanco) {
      final res = disparar(t, col, fila,
          costo: costoIncendiaria, danoBase: danoIncendiaria);
      if (res == null) return null;
      texto = res;
    } else {
      // Casilla vacía: solo prende fuego
      _usarCicloParaDisparar(t);
      _gastarEnergia(costoIncendiaria, t);
      dispararon.add(t.id);
      texto = 'Disparo incendiario sin impacto';
    }
    final k = idx(col, fila);
    fuegos[k] = turnosFuego;
    fuegoDueno[k] = t.jugador;
    return '$texto · casilla en llamas ($turnosFuego turnos)';
  }

  /// Ultimate · Bombardeo de Precisión: 3 columnas de ancho por 4 filas de largo,
  /// orientado según la dirección del tanque. La casilla elegida debe estar a
  /// 5 casillas como máximo del Artillero (sin necesitar visión).
  Set<int> casillasBombardeo(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.artilleria || !puedeDisparar(t)) return res;
    final r = _rangoArtillero(t, rangoBombardeo);
    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, r)) continue;
        res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Casillas que cubre el bombardeo. La zona se genera con el vector de
  /// dirección actual del tanque (8 direcciones posibles), y la casilla elegida
  /// es la primera del haz (la más cercana al Artillero).
  ({Set<int> centro, Set<int> lados}) zonaBombardeo(
      Tanque t, int col, int fila) {
    final dirCol = t.dirCol == 0 && t.dirFila == 0 ? 0 : t.dirCol;
    final dirFila = t.dirCol == 0 && t.dirFila == 0 ? (t.jugador == 1 ? -1 : 1) : t.dirFila;
    final forwardCol = dirCol == 0 ? 0 : dirCol.sign;
    final forwardFila = dirFila == 0 ? 0 : dirFila.sign;
    final rightCol = -forwardFila;
    final rightFila = forwardCol;
    final centro = <int>{};
    final lados = <int>{};
    final mitad = bombardeoAncho ~/ 2;
    for (var i = 0; i < bombardeoLargo; i++) {
      final cBase = col + forwardCol * i;
      final fBase = fila + forwardFila * i;
      if (cBase < 0 || cBase >= columnas || fBase < 0 || fBase >= filas) {
        continue;
      }
      for (var dc = -mitad; dc <= mitad; dc++) {
        final c = cBase + rightCol * dc;
        final f = fBase + rightFila * dc;
        if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
        (dc == 0 ? centro : lados).add(idx(c, f));
      }
    }
    return (centro: centro, lados: lados);
  }

  /// Columna central 80, laterales 40 y los muros atrapados 38. No daña
  /// aliados. La pasiva ignora 20% del Armor si el Artillero estuvo quieto.
  String? bombardeo(Tanque t, int col, int fila) {
    if (!casillasBombardeo(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoBombardeo)) return null;
    final zona = zonaBombardeo(t, col, fila);
    final pct = pasivaArtilleriaActiva(t) ? armorIgnoradoPasiva : 0.0;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoBombardeo, t);
    dispararon.add(t.id);

    final golpes = <String>[];
    for (final o in List<Tanque>.from(tanques)) {
      if (o.jugador == t.jugador) continue;
      final k = idx(o.col, o.fila);
      final base = zona.centro.contains(k)
          ? danoBombardeoCentro
          : zona.lados.contains(k)
              ? danoBombardeoLado
              : 0;
      if (base == 0) continue;
      final r = _danarTanque(o, _conRampa(t, base),
          armorIgnorado: pct, atacante: t);
      var s = '${o.clase.nombre} -${r[0] + r[1]}';
      if (o.vida <= 0) {
        tanques.remove(o);
        s += ' (destruido)';
      }
      golpes.add(s);
    }

    var muros = 0;
    for (final k in {...zona.centro, ...zona.lados}) {
      final muro = obstaculoEn(k % columnas, k ~/ columnas);
      if (muro == null || !muro.tipo.esMuro) continue;
      muro.hp -= _conRampa(t, danoBombardeoMuro);
      muros++;
      if (muro.hp <= 0) {
        obstaculos.remove(muro);
        duenos.remove(muro);
      }
    }

    _revisarVictoria(t.jugador);
    final partes = <String>[
      if (golpes.isNotEmpty) golpes.join(', '),
      if (muros > 0) '$muros muro(s) dañados',
    ];
    return partes.isEmpty
        ? 'Bombardeo sin objetivos'
        : 'Bombardeo: ${partes.join(' · ')}';
  }

  // ---------- Fuego y bengalas ----------

  /// Al empezar el turno de [jugador]: sus tanques parados en una casilla en
  /// llamas del rival reciben daño directo a la vida (ignora Armor).
  void _aplicarFuego() {
    for (final t in List<Tanque>.from(tanques)) {
      if (t.jugador != jugador) continue;
      final k = idx(t.col, t.fila);
      final dueno = fuegoDueno[k];
      if (!fuegos.containsKey(k) || dueno == null || dueno == t.jugador) {
        continue;
      }
      t.vida -= danoFuego;
      var s = '${t.clase.nombre} se quema: -$danoFuego HP';
      if (t.vida <= 0) {
        tanques.remove(t);
        s += ' · ¡destruido!';
        _revisarVictoria(dueno);
      }
      _evento(s);
    }
  }

  /// Al terminar el turno de su dueño, el fuego y las bengalas gastan un turno.
  void _avanzarFuegosYBengalas() {
    for (final k in fuegos.keys.toList()) {
      if (fuegoDueno[k] != jugador) continue;
      final quedan = fuegos[k]! - 1;
      if (quedan <= 0) {
        fuegos.remove(k);
        fuegoDueno.remove(k);
      } else {
        fuegos[k] = quedan;
      }
    }
    for (final b in bengalas.toList()) {
      if (b.jugador != jugador) continue;
      b.turnos--;
      if (b.turnos <= 0) bengalas.remove(b);
    }
  }

  /// Un muro de sacos del rival dentro de una bengala no cuenta.
  bool _muroAnuladoPorBengala(int col, int fila) {
    final o = obstaculoEn(col, fila);
    if (o == null || o.tipo != TipoObstaculo.sacos) return false;
    final dueno = duenos[o];
    if (dueno == null) return false; // los del mapa son neutrales
    for (final b in bengalas) {
      if (b.jugador != dueno && b.cubre(col, fila)) return true;
    }
    return false;
  }

  /// Muro que bloquea visión y da cobertura (no está anulado por una bengala).
  bool _muroEfectivo(int col, int fila) =>
      _esMuro(col, fila) && !_muroAnuladoPorBengala(col, fila);

  // ---------- Sembrador ----------

  int minasPresionDe(int jugador) => minas.values
      .where((m) => m.dueno == jugador && m.tipo == TipoMina.presion)
      .length;

  /// Casilla donde se puede dejar una mina: sin tanque, muro ni otra mina.
  bool _libreParaMina(int col, int fila) {
    if (col < 0 || col >= columnas || fila < 0 || fila >= filas) return false;
    return tanqueEn(col, fila) == null &&
        !_esMuro(col, fila) &&
        !minas.containsKey(idx(col, fila));
  }

  bool _tieneExplosivo(int jugador) =>
      minas.values.any((m) => m.dueno == jugador) ||
      lapas.entries
          .any((e) => e.value.dueno == jugador && tanquePorId(e.key) != null);

  /// Pasiva · Paso Seguro (parte 2): +10 de Armor mientras el Sembrador tenga
  /// al menos un explosivo (mina o Carga Lapa) activo en el tablero.
  /// (La parte 1, no activar minas, está en [_pisarMina].)
  void _sincronizarPasivaSembrador() {
    for (final t in tanques) {
      if (t.clase != ClaseTanque.sembrador) continue;
      final debe = _tieneExplosivo(t.jugador);
      final tiene = _sembradoresBlindados.contains(t.id);
      if (debe && !tiene) {
        t.armor += armorPasivaSembrador;
        t.armorExtra += armorPasivaSembrador;
        _sembradoresBlindados.add(t.id);
      } else if (!debe && tiene) {
        t.armor = math.max(0, t.armor - armorPasivaSembrador);
        t.armorExtra = math.max(0, t.armorExtra - armorPasivaSembrador);
        _sembradoresBlindados.remove(t.id);
      }
    }
  }

  void _revisarAmbos(int primero) {
    if (ganador != null) return;
    _revisarVictoria(primero);
    if (ganador == null) _revisarVictoria(primero == 1 ? 2 : 1);
  }

  /// Se llama cuando un tanque termina en una casilla nueva. Si hay una mina,
  /// la activa (el Sembrador es inmune). Devuelve el aviso, o null si no pasó nada.
  /// - Presión: solo la activa un enemigo. 50 de daño y queda Atascado.
  /// - Fragmentación: la activa cualquiera; 40 de daño en cruz.
  /// - Un Zapador aliado del dueño la desactiva al pisarla.
  String? _pisarMina(Tanque t) {
    if (t.clase == ClaseTanque.sembrador) return null;
    final k = idx(t.col, t.fila);
    final m = minas[k];
    if (m == null) return null;

    if (t.clase == ClaseTanque.zapador && t.jugador == m.dueno) {
      minas.remove(k);
      _sincronizarPasivaSembrador();
      return 'Zapador desactivó una mina';
    }

    if (m.tipo == TipoMina.presion) {
      if (t.jugador == m.dueno) return null;
      minas.remove(k);
      final r = _danarTanque(t, danoMinaPresion, ignoraArmor: minaIgnoraArmor);
      var s = '¡Mina! ${t.clase.nombre} -${r[0] + r[1]} '
          '(Armor -${r[0]}, HP -${r[1]})';
      if (t.vida <= 0) {
        tanques.remove(t);
        s += ' · ¡destruido!';
        _revisarAmbos(m.dueno);
      } else {
        aplicarEstado(t, EstadoTanque.atascado);
        s += ' · Atascado';
      }
      _sincronizarPasivaSembrador();
      return s;
    }

    // Fragmentación: el centro y las 4 casillas vecinas (forma de cruz)
    minas.remove(k);
    final cruz = {
      k,
      if (t.col > 0) idx(t.col - 1, t.fila),
      if (t.col < columnas - 1) idx(t.col + 1, t.fila),
      if (t.fila > 0) idx(t.col, t.fila - 1),
      if (t.fila < filas - 1) idx(t.col, t.fila + 1),
    };
    final golpes = <String>[];
    for (final o in List<Tanque>.from(tanques)) {
      if (!cruz.contains(idx(o.col, o.fila))) continue;
      final r = _danarTanque(o, danoMinaFragmentacion);
      var s = '${o.clase.nombre} -${r[0] + r[1]}';
      if (o.vida <= 0) {
        tanques.remove(o);
        s += ' (destruido)';
      }
      golpes.add(s);
    }
    _revisarAmbos(m.dueno);
    _sincronizarPasivaSembrador();
    return '¡Mina de fragmentación! ${golpes.join(', ')}';
  }

  /// Habilidad 2 · Mina de Presión Oculta: casillas libres a su rango (2).
  Set<int> casillasMina(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.sembrador || !puedeDisparar(t)) return res;
    if (minasPresionDe(t.jugador) >= maxMinasPresion) return res;
    final r = rangoEfectivo(t);
    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, r)) continue;
        if (_libreParaMina(c, f)) res.add(idx(c, f));
      }
    }
    return res;
  }

  String? ponerMina(Tanque t, int col, int fila) {
    if (!casillasMina(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoMina)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoMina, t);
    dispararon.add(t.id);
    minas[idx(col, fila)] = Mina(TipoMina.presion, t.jugador);
    _sincronizarPasivaSembrador();
    return 'Mina colocada (${minasPresionDe(t.jugador)}/$maxMinasPresion)';
  }

  /// Habilidad 3 · Carga Lapa: enemigos a rango 2 con visión y sin bomba pegada.
  Set<int> objetivosLapa(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.sembrador || !puedeDisparar(t)) return res;
    for (final k in rangoDe(t).objetivos) {
      final o = tanqueEn(k % columnas, k ~/ columnas);
      if (o != null && !lapas.containsKey(o.id)) res.add(k);
    }
    return res;
  }

  /// Pega la bomba. Explota al empezar el siguiente turno del Sembrador
  /// (45 de daño que ignora 50% del Armor) y viaja con el tanque si se mueve.
  String? cargaLapa(Tanque t, int col, int fila) {
    if (!objetivosLapa(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoLapa)) return null;
    final o = tanqueEn(col, fila);
    if (o == null) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoLapa, t);
    dispararon.add(t.id);
    lapas[o.id] = Lapa(t.id, t.jugador);
    _sincronizarPasivaSembrador();
    return 'Carga Lapa pegada a ${o.clase.nombre}: explota al inicio de tu '
        'próximo turno';
  }

  void _detonarLapas() {
    for (final id in lapas.keys.toList()) {
      final l = lapas[id]!;
      if (l.dueno != jugador) continue;
      lapas.remove(id);
      final v = tanquePorId(id);
      if (v == null) continue;
      final r = _danarTanque(v, danoLapa, armorIgnorado: armorLapaIgnorado);
      var s = 'Carga Lapa explota en ${v.clase.nombre}: -${r[0] + r[1]} '
          '(Armor -${r[0]}, HP -${r[1]})';
      if (v.vida <= 0) {
        tanques.remove(v);
        s += ' · ¡destruido!';
        _revisarAmbos(l.dueno);
      }
      _evento(s);
    }
    _sincronizarPasivaSembrador();
  }

  /// Ultimate · Campo Minado de Saturación: centro del 3x3, a rango fijo 4.
  Set<int> casillasCampo(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.sembrador || !puedeDisparar(t)) return res;
    final r = rangoCampo;
    for (int f = 0; f < filas; f++) {
      for (int c = 0; c < columnas; c++) {
        final dx = c - t.col;
        final dy = f - t.fila;
        if ((dx == 0 && dy == 0) || !enForma(dx, dy, r)) continue;
        res.add(idx(c, f));
      }
    }
    return res;
  }

  /// Casillas del 3x3 (recortado por el borde) para la vista previa.
  Set<int> cuadranteCampo(int col, int fila) => {
        for (var dc = -1; dc <= 1; dc++)
          for (var df = -1; df <= 1; df++)
            if (col + dc >= 0 &&
                col + dc < columnas &&
                fila + df >= 0 &&
                fila + df < filas)
              idx(col + dc, fila + df),
      };

  /// Reparte 3 minas de fragmentación al azar en las casillas vacías del 3x3.
  String? campoMinado(Tanque t, int col, int fila) {
    if (!casillasCampo(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoCampo)) return null;
    final libres = [
      for (final k in cuadranteCampo(col, fila))
        if (_libreParaMina(k % columnas, k ~/ columnas)) k,
    ]..shuffle(_azar);
    if (libres.isEmpty) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoCampo, t);
    dispararon.add(t.id);
    final n = math.min(minasCampo, libres.length);
    for (final k in libres.take(n)) {
      minas[k] = Mina(TipoMina.fragmentacion, t.jugador);
    }
    _sincronizarPasivaSembrador();
    return 'Campo minado: $n mina(s) de fragmentación esparcidas';
  }

  // ---------- Soporte ----------

  /// Suma Armor sin pasar del máximo. Devuelve cuánto se dio realmente.
  int _darArmor(Tanque o, int cantidad) {
    final tope = o.armorMaximo;
    if (o.armor >= tope) return 0;
    final nuevo = math.min(tope, o.armor + cantidad);
    final dado = nuevo - o.armor;
    o.armor = nuevo;
    return dado;
  }

  /// Pasiva · Logística de Pelotón: al empezar su turno, cada aliado pegado
  /// a un Soporte (8 casillas vecinas) gana +10 de Armor. No se acumula entre
  /// dos Soportes. (La parte de +2 EN al quedarse quieto está en
  /// [_generarEnergiaQuieta].)
  void _aplicarPasivaSoporte() {
    final reforzados = <int>{};
    for (final s in tanques) {
      if (s.jugador != jugador || s.clase != ClaseTanque.soporte) continue;
      for (final d in _vecinos8) {
        final a = tanqueEn(s.col + d[0], s.fila + d[1]);
        if (a == null || a.jugador != jugador) continue;
        if (_darArmor(a, armorPasivaSoporte) > 0) reforzados.add(a.id);
      }
    }
    if (reforzados.isNotEmpty) {
      _evento('Logística de Pelotón: +$armorPasivaSoporte Armor a '
          '${reforzados.length} aliado(s)');
    }
  }

  /// Habilidad 2 · Unidad de Reparación de Campaña: aliados en las 8 casillas
  /// vecinas (nunca a sí mismo).
  Set<int> objetivosReparacion(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.soporte || !puedeDisparar(t)) return res;
    for (final d in _vecinos8) {
      final a = tanqueEn(t.col + d[0], t.fila + d[1]);
      if (a != null && a.jugador == t.jugador) res.add(idx(a.col, a.fila));
    }
    return res;
  }

  /// +30 de HP (sin pasar del máximo) y +10% del Armor máximo del aliado.
  String? repararAliado(Tanque t, int col, int fila) {
    if (!objetivosReparacion(t).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoReparacion)) return null;
    final a = tanqueEn(col, fila);
    if (a == null) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoReparacion, t);
    dispararon.add(t.id);

    final hp = math.max(0, math.min(curacionReparacion, a.clase.vida - a.vida));
    a.vida += hp;
    final armor = _darArmor(a, (a.armorMaximo * armorReparacionPct).round());
    return 'Reparación: ${a.clase.nombre} +$hp HP, +$armor Armor';
  }

  /// Habilidad 3 · Cable de Remolque, paso 1: aliados a rango 2 con visión.
  Set<int> objetivosCable(Tanque t) {
    final res = <int>{};
    if (t.clase != ClaseTanque.soporte || !puedeDisparar(t)) return res;
    for (final a in tanques) {
      if (a.jugador != t.jugador || a.id == t.id) continue;
      if (!enForma(a.col - t.col, a.fila - t.fila, rangoCable)) continue;
      if (!hayVision(t.col, t.fila, a.col, a.fila)) continue;
      res.add(idx(a.col, a.fila));
    }
    return res;
  }

  /// Paso 2: [jalar] = true → el aliado llega a una casilla vecina al Soporte;
  /// false → el Soporte va a una casilla vecina al aliado. Un Pesado
  /// atrincherado es inmune a ser reposicionado.
  Set<int> destinosCable(Tanque t, Tanque aliado, bool jalar) {
    final res = <int>{};
    if (jalar && trincherados.contains(aliado.id)) return res;
    final ancla = jalar ? t : aliado;
    for (final d in _vecinos8) {
      final c = ancla.col + d[0];
      final f = ancla.fila + d[1];
      if (c < 0 || c >= columnas || f < 0 || f >= filas) continue;
      if (tanqueEn(c, f) != null || _esMuro(c, f)) continue;
      res.add(idx(c, f));
    }
    return res;
  }

  String? cableRemolque(Tanque t, Tanque aliado, bool jalar, int col, int fila) {
    if (!objetivosCable(t).contains(idx(aliado.col, aliado.fila))) return null;
    if (!destinosCable(t, aliado, jalar).contains(idx(col, fila))) return null;
    if (!puedePagarDisparo(t, costoCable)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoCable, t);
    dispararon.add(t.id);

    final movido = jalar ? aliado : t;
    movido.col = col;
    movido.fila = fila;
    if (!jalar) _marcarMovido(t); // el Soporte sí se desplazó
    final atascado = _alLlegarACasilla(movido);
    final mina = _pisarMina(movido);
    final accion = jalar
        ? 'Cable: ${aliado.clase.nombre} jalado'
        : 'Cable: el Soporte se acerca a ${aliado.clase.nombre}';
    return '$accion'
        '${atascado ? ' · cayó en la tinta: Atascado' : ''}'
        '${mina != null ? '\n$mina' : ''}';
  }

  /// Ultimate · Estación de Reabastecimiento Masivo: zona 3x3 centrada en el
  /// Soporte, fija en el tablero. Al crearla limpia los estados negativos de
  /// los aliados dentro. Solo una Estación activa por jugador.
  bool puedeEstacion(Tanque t) =>
      t.clase == ClaseTanque.soporte &&
      puedeDisparar(t) &&
      !estaciones.any((e) => e.jugador == t.jugador);

  String? activarEstacion(Tanque t) {
    if (!puedeEstacion(t)) return null;
    if (!puedePagarDisparo(t, costoEstacion)) return null;
    _usarCicloParaDisparar(t);
    _gastarEnergia(costoEstacion, t);
    dispararon.add(t.id);

    final e = Estacion(
      col: t.col,
      fila: t.fila,
      jugador: t.jugador,
      turnos: turnosEstacion,
    );
    estaciones.add(e);
    var limpiados = 0;
    for (final a in tanques) {
      if (a.jugador != t.jugador || !e.cubre(a.col, a.fila)) continue;
      if (estadosDe(a).any((s) => s.negativo)) limpiados++;
      limpiarEstadosNegativos(a);
    }
    return 'Estación de Reabastecimiento: zona 3x3 por $turnosEstacion turnos'
        ' · $limpiados aliado(s) limpiados de estados negativos';
  }

  /// Al empezar el turno de su dueño, los aliados dentro de la Estación
  /// recuperan HP y Armor y sus habilidades comunes cuestan -1 EN este turno.
  void _aplicarEstaciones() {
    for (final e in estaciones) {
      if (e.jugador != jugador) continue;
      var ayudados = 0;
      for (final a in tanques) {
        if (a.jugador != jugador || !e.cubre(a.col, a.fila)) continue;
        final hp = math.max(0, math.min(curacionEstacion, a.clase.vida - a.vida));
        a.vida += hp;
        _darArmor(a, armorEstacion);
        conDescuento.add(a.id);
        ayudados++;
      }
      if (ayudados > 0) {
        _evento('Estación: $ayudados aliado(s) reabastecidos '
            '(+$curacionEstacion HP, +$armorEstacion Armor, -$descuentoEstacion EN)');
      }
    }
  }

  /// Al terminar el turno de su dueño, la Estación gasta un turno.
  void _avanzarEstaciones() {
    for (final e in estaciones.toList()) {
      if (e.jugador != jugador) continue;
      e.turnos--;
      if (e.turnos <= 0) estaciones.remove(e);
    }
  }
}
