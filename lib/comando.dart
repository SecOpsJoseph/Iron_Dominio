import 'juego_estado.dart';
import 'tanque.dart';

/// Todo lo que un jugador puede hacer en la partida. Cada acción viaja como un
/// [Comando] (se puede convertir a JSON), así los dos celulares y el servidor
/// aplican exactamente lo mismo con [EstadoJuego.aplicar].
/// ClaseTanque no es un enum, así que cada clase viaja por la red con esta clave.
const Map<String, ClaseTanque> _clasesPorClave = {
  'pesado': ClaseTanque.pesado,
  'zapador': ClaseTanque.zapador,
  'soporte': ClaseTanque.soporte,
  'sembrador': ClaseTanque.sembrador,
  'ligero': ClaseTanque.ligero,
  'artilleria': ClaseTanque.artilleria,
};

extension ClaveClaseTanque on ClaseTanque {
  String get clave =>
      _clasesPorClave.entries.firstWhere((e) => identical(e.value, this)).key;
}

ClaseTanque? claseDeClave(String clave) => _clasesPorClave[clave];

enum TipoComando {
  // Despliegue
  colocar, // clase, col, fila
  quitar, // col, fila
  confirmarDespliegue,
  // Turno
  terminarTurno,
  mover, // tanqueId, col, fila
  girar, // tanqueId
  // Ataques
  disparar, // tanqueId, col, fila (disparo básico de cualquier clase)
  perforante, // Ligero
  escape, // Ligero
  completarEscape, // tanqueId, col, fila
  rafaga, // Ligero (ultimate): destino
  trinchera, // Pesado
  embestida, // Pesado: casilla
  sacrificio, // Pesado (ultimate): objetivo
  sacos, // Zapador: casilla
  rompemuros, // Zapador: casilla del enemigo
  operacion, // Zapador (ultimate): celdas (2)
  bengala, // Artillero
  incendiaria, // Artillero
  bombardeo, // Artillero (ultimate)
  mina, // Sembrador
  lapa, // Sembrador
  campo, // Sembrador (ultimate)
  reparar, // Soporte: casilla del aliado
  cable, // Soporte: aliadoId, jalar, casilla destino
  estacion, // Soporte (ultimate)
}

class Comando {
  final TipoComando tipo;

  /// Quién lo envía (1 o 2). El servidor lo compara con el jugador de turno.
  final int jugador;
  final int? tanqueId;
  final int? col;
  final int? fila;

  /// Clave de la clase (ClaseTanque.clave), solo para [TipoComando.colocar].
  final String? clase;

  /// Casillas (índices del tablero), solo para [TipoComando.operacion].
  final List<int>? celdas;

  /// Solo para [TipoComando.cable].
  final int? aliadoId;
  final bool? jalar;

  const Comando({
    required this.tipo,
    required this.jugador,
    this.tanqueId,
    this.col,
    this.fila,
    this.clase,
    this.celdas,
    this.aliadoId,
    this.jalar,
  });

  Map<String, dynamic> toJson() => {
        'tipo': tipo.name,
        'jugador': jugador,
        if (tanqueId != null) 'tanqueId': tanqueId,
        if (col != null) 'col': col,
        if (fila != null) 'fila': fila,
        if (clase != null) 'clase': clase,
        if (celdas != null) 'celdas': celdas,
        if (aliadoId != null) 'aliadoId': aliadoId,
        if (jalar != null) 'jalar': jalar,
      };

  /// Lanza una excepción si el JSON no es válido (el servidor debe atraparla
  /// y rechazar el mensaje).
  factory Comando.fromJson(Map<String, dynamic> j) => Comando(
        tipo: TipoComando.values.byName(j['tipo'] as String),
        jugador: j['jugador'] as int,
        tanqueId: j['tanqueId'] as int?,
        col: j['col'] as int?,
        fila: j['fila'] as int?,
        clase: j['clase'] as String?,
        celdas: (j['celdas'] as List?)?.cast<int>(),
        aliadoId: j['aliadoId'] as int?,
        jalar: j['jalar'] as bool?,
      );

  @override
  String toString() => 'Comando(${toJson()})';
}

class ResultadoComando {
  final bool ok;
  final String texto;
  const ResultadoComando(this.ok, this.texto);
}

/// Repite una partida desde cero: misma semilla + mismos comandos = mismo
/// resultado. Lanza StateError si algún comando no es válido.
EstadoJuego reproducir(int semilla, Iterable<Comando> comandos) {
  final j = EstadoJuego(semilla: semilla);
  for (final c in comandos) {
    final r = j.aplicar(c);
    if (!r.ok) throw StateError('Comando inválido: $c (${r.texto})');
  }
  return j;
}

extension AplicarComando on EstadoJuego {
  /// Único punto de entrada para jugar. Valida que sea el turno de quien envía
  /// y que la acción sea legal; si lo es, la aplica y la guarda en [historial].
  ResultadoComando aplicar(Comando c) {
    if (ganador != null) return const ResultadoComando(false, 'La partida terminó');
    if (c.jugador != jugador) return const ResultadoComando(false, 'No es tu turno');
    final texto = _ejecutar(c);
    if (texto == null) return const ResultadoComando(false, 'Acción no válida');
    historial.add(c);
    return ResultadoComando(true, texto);
  }

  /// Devuelve el texto del resultado ('' si no hay), o null si no es válido.
  String? _ejecutar(Comando c) {
    final enDespliegue = fase == Fase.despliegue;

    switch (c.tipo) {
      case TipoComando.colocar:
        if (!enDespliegue || c.clase == null || c.col == null || c.fila == null) {
          return null;
        }
        final clase = claseDeClave(c.clase!);
        if (clase == null) return null;
        return colocarTanque(clase, c.col!, c.fila!) ? '' : null;

      case TipoComando.quitar:
        if (!enDespliegue || c.col == null || c.fila == null) return null;
        final propio = tanqueEn(c.col!, c.fila!);
        if (propio == null || propio.jugador != jugador) return null;
        quitarTanque(propio);
        return '';

      case TipoComando.confirmarDespliegue:
        if (!enDespliegue || contar(jugador) != tanquesPorJugador) return null;
        confirmarDespliegue();
        return '';

      case TipoComando.terminarTurno:
        if (enDespliegue) return null;
        terminarTurno();
        return ultimoEvento;

      default:
        break;
    }

    // Todo lo demás es de la fase de juego y lo hace un tanque propio.
    if (enDespliegue) return null;
    final t = c.tanqueId == null ? null : tanquePorId(c.tanqueId!);
    if (t == null || t.jugador != jugador) return null;
    final hayCasilla = c.col != null && c.fila != null;
    final col = c.col ?? -1; // solo se usan si [hayCasilla]
    final fila = c.fila ?? -1;

    switch (c.tipo) {
      case TipoComando.mover:
        if (!hayCasilla || !alcanzables(t).contains(EstadoJuego.idx(col, fila))) {
          return null;
        }
        return mover(t, col, fila) ?? '';

      case TipoComando.girar:
        girar(t);
        return '';

      case TipoComando.disparar:
        return hayCasilla ? disparar(t, col, fila) : null;

      case TipoComando.perforante:
        if (!hayCasilla || t.clase != ClaseTanque.ligero) return null;
        return disparar(t, col, fila,
            costo: EstadoJuego.costoPerforante, ignoraArmor: true);

      case TipoComando.escape:
        if (!hayCasilla || t.clase != ClaseTanque.ligero) return null;
        return disparar(t, col, fila,
            costo: EstadoJuego.costoEscape, escape: true);

      case TipoComando.completarEscape:
        return hayCasilla ? completarEscape(t, col, fila) : null;

      case TipoComando.rafaga:
        return hayCasilla ? rafaga(t, col, fila) : null;

      case TipoComando.trinchera:
        final antes = trincherados.contains(t.id);
        final texto = activarTrinchera(t);
        return !antes && trincherados.contains(t.id) ? texto : null;

      case TipoComando.embestida:
        return hayCasilla ? embestir(t, col, fila) : null;

      case TipoComando.sacrificio:
        return hayCasilla ? sacrificio(t, col, fila) : null;

      case TipoComando.sacos:
        return hayCasilla ? construirSacos(t, col, fila) : null;

      case TipoComando.rompemuros:
        return hayCasilla ? rompemuros(t, col, fila) : null;

      case TipoComando.operacion:
        return c.celdas == null ? null : operacionTrinchera(t, c.celdas!);

      case TipoComando.bengala:
        return hayCasilla ? lanzarBengala(t, col, fila) : null;

      case TipoComando.incendiaria:
        return hayCasilla ? incendiaria(t, col, fila) : null;

      case TipoComando.bombardeo:
        return hayCasilla ? bombardeo(t, col, fila) : null;

      case TipoComando.mina:
        return hayCasilla ? ponerMina(t, col, fila) : null;

      case TipoComando.lapa:
        return hayCasilla ? cargaLapa(t, col, fila) : null;

      case TipoComando.campo:
        return hayCasilla ? campoMinado(t, col, fila) : null;

      case TipoComando.reparar:
        return hayCasilla ? repararAliado(t, col, fila) : null;

      case TipoComando.cable:
        if (!hayCasilla || c.aliadoId == null || c.jalar == null) return null;
        final aliado = tanquePorId(c.aliadoId!);
        if (aliado == null) return null;
        return cableRemolque(t, aliado, c.jalar!, col, fila);

      case TipoComando.estacion:
        return activarEstacion(t);

      case TipoComando.colocar:
      case TipoComando.quitar:
      case TipoComando.confirmarDespliegue:
      case TipoComando.terminarTurno:
        return null; // ya resueltos arriba
    }
  }
}
