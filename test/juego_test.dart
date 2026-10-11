// Cambia iron_dominio por el nombre de tu paquete (campo "name" de pubspec.yaml).
import 'package:flutter_test/flutter_test.dart';
import 'package:iron_dominio/comando.dart';
import 'package:iron_dominio/juego_estado.dart';
import 'package:iron_dominio/estado_tanque.dart';
import 'package:iron_dominio/obstaculo_modelo.dart';
import 'package:iron_dominio/tanque.dart';

Comando cmd(TipoComando tipo, int jugador,
        {int? tanque, int? col, int? fila, String? clase, int? aliado, bool? jalar, List<int>? celdas}) =>
    Comando(
      tipo: tipo,
      jugador: jugador,
      tanqueId: tanque,
      col: col,
      fila: fila,
      clase: clase,
      aliadoId: aliado,
      jalar: jalar,
      celdas: celdas,
    );

/// Partida lista para jugar. Ids: J1 = 1,2,3 · J2 = 4,5,6 (en el orden dado).
/// Quita los obstáculos para que las pruebas no dependan del mapa.
EstadoJuego partida({
  int semilla = 1,
  List<ClaseTanque> j1 = const [ClaseTanque.ligero, ClaseTanque.zapador, ClaseTanque.pesado],
  List<ClaseTanque> j2 = const [ClaseTanque.zapador, ClaseTanque.ligero, ClaseTanque.pesado],
  bool sinObstaculos = true,
}) {
  final j = EstadoJuego(semilla: semilla);
  void desplegar(int jugador, List<ClaseTanque> clases, int fila) {
    for (var i = 0; i < clases.length; i++) {
      final r = j.aplicar(cmd(TipoComando.colocar, jugador,
          clase: clases[i].clave, col: 2 + i * 2, fila: fila));
      expect(r.ok, isTrue, reason: r.texto);
    }
    final r = j.aplicar(cmd(TipoComando.confirmarDespliegue, jugador));
    expect(r.ok, isTrue, reason: r.texto);
  }

  desplegar(1, j1, filas - 1);
  desplegar(2, j2, 0);
  if (sinObstaculos) j.obstaculos.clear();
  return j;
}

void ubicar(EstadoJuego j, int id, int col, int fila) {
  final t = j.tanquePorId(id)!;
  t.col = col;
  t.fila = fila;
}

String huella(EstadoJuego j) => (j.obstaculos
        .map((o) => '${o.tipo.name}@${o.col},${o.fila}')
        .toList()
      ..sort())
    .join('|');

void main() {
  group('Azar con semilla y comandos', () {
    test('misma semilla = mismo mapa', () {
      expect(huella(partida(semilla: 7, sinObstaculos: false)),
          huella(partida(semilla: 7, sinObstaculos: false)));
    });

    test('el mapa es simétrico (girado 180°)', () {
      final j = partida(semilla: 3, sinObstaculos: false);
      for (final o in j.obstaculos) {
        final espejo = j.obstaculoEn(columnas - 1 - o.col, filas - 1 - o.fila);
        expect(espejo, isNotNull);
        expect(espejo!.tipo, o.tipo);
      }
    });

    test('un comando sobrevive a JSON', () {
      final c = cmd(TipoComando.cable, 1, tanque: 1, aliado: 2, jalar: true, col: 4, fila: 6);
      final de = Comando.fromJson(c.toJson());
      expect(de.toJson(), c.toJson());
      final op = cmd(TipoComando.operacion, 2, tanque: 4, celdas: [10, 11]);
      expect(Comando.fromJson(op.toJson()).celdas, [10, 11]);
    });

    test('repetir los comandos con la misma semilla da la misma partida', () {
      final j = partida(semilla: 11, sinObstaculos: false);
      j.aplicar(cmd(TipoComando.terminarTurno, 1));
      final copia = reproducir(11, j.historial);
      expect(huella(copia), huella(j));
      expect(copia.jugador, j.jugador);
      expect(copia.energia, j.energia);
    });
  });

  group('Turnos y despliegue', () {
    test('no se puede jugar fuera de turno', () {
      final j = partida();
      final r = j.aplicar(cmd(TipoComando.terminarTurno, 2));
      expect(r.ok, isFalse);
      expect(j.jugador, 1);
    });

    test('despliegue: solo tu zona y máximo 3 tanques', () {
      final j = EstadoJuego(semilla: 1);
      expect(j.aplicar(cmd(TipoComando.colocar, 1, clase: 'ligero', col: 0, fila: 5)).ok, isFalse);
      for (var i = 0; i < 3; i++) {
        expect(j.aplicar(cmd(TipoComando.colocar, 1, clase: 'ligero', col: i, fila: filas - 1)).ok, isTrue);
      }
      expect(j.aplicar(cmd(TipoComando.colocar, 1, clase: 'ligero', col: 5, fila: filas - 1)).ok, isFalse);
      expect(j.aplicar(cmd(TipoComando.colocar, 2, clase: 'ligero', col: 0, fila: 0)).ok, isFalse,
          reason: 'es el turno del J1');
    });

    test('energía: 1 EN por tanque (máx. 3) al empezar cada turno', () {
      final j = partida();
      expect(j.energia[1], 3);
      expect(j.energia[2], 0);
      j.aplicar(cmd(TipoComando.terminarTurno, 1));
      expect(j.energia[2], 3);
    });

    test('cada tanque tiene un ciclo: mover una vez, no dos', () {
      final j = partida();
      final destino = j.alcanzables(j.tanquePorId(1)!).first;
      final c = destino % columnas;
      final f = destino ~/ columnas;
      expect(j.aplicar(cmd(TipoComando.mover, 1, tanque: 1, col: c, fila: f)).ok, isTrue);
      final otro = j.alcanzables(j.tanquePorId(1)!);
      expect(otro, isEmpty);
    });
  });

  group('Combate', () {
    test('el disparo básico quita exactamente su daño (Armor + HP)', () {
      final j = partida();
      ubicar(j, 1, 4, 5); // Ligero J1
      ubicar(j, 4, 4, 4); // Zapador J2, al lado
      final atacante = j.tanquePorId(1)!;
      final blanco = j.tanquePorId(4)!;
      final antes = blanco.vida + blanco.armor;
      final r = j.aplicar(cmd(TipoComando.disparar, 1, tanque: 1, col: 4, fila: 4));
      expect(r.ok, isTrue, reason: r.texto);
      expect(antes - (blanco.vida + blanco.armor), j.danoDisparo(atacante));
    });

    test('matar al último tanque enemigo gana la partida', () {
      final j = partida();
      j.tanques.removeWhere((t) => t.jugador == 2 && t.id != 4);
      ubicar(j, 1, 4, 5);
      ubicar(j, 4, 4, 4);
      final blanco = j.tanquePorId(4)!;
      blanco.armor = 0;
      blanco.vida = 1;
      expect(j.aplicar(cmd(TipoComando.disparar, 1, tanque: 1, col: 4, fila: 4)).ok, isTrue);
      expect(j.ganador, 1);
      expect(j.aplicar(cmd(TipoComando.terminarTurno, 1)).ok, isFalse);
    });

    test('no puedes mover ni disparar con un tanque rival', () {
      final j = partida();
      expect(j.aplicar(cmd(TipoComando.girar, 1, tanque: 4)).ok, isFalse);
    });

    test('bombardeo: máximo rango 5 y orienta en 8 direcciones', () {
      final j = partida(j1: [ClaseTanque.artilleria, ClaseTanque.zapador, ClaseTanque.pesado]);
      final art = j.tanquePorId(1)!;
      art.col = 4;
      art.fila = 5;

      expect(j.casillasBombardeo(art).contains(EstadoJuego.idx(4, 0)), isTrue,
          reason: 'a 5 casillas sí se puede');
      expect(j.casillasBombardeo(art).contains(EstadoJuego.idx(4, -1)), isFalse,
          reason: 'no debe llegar más allá del rango 5');

      art.dirCol = 1;
      art.dirFila = 0;
      final horizontal = j.zonaBombardeo(art, 6, 5);
      expect(horizontal.centro.contains(EstadoJuego.idx(6, 5)), isTrue);
      expect(horizontal.centro.contains(EstadoJuego.idx(6, 4)), isFalse,
          reason: 'la zona horizontal no debe extenderse en vertical');

      art.dirCol = 1;
      art.dirFila = -1;
      final diagonal = j.zonaBombardeo(art, 6, 4);
      expect(diagonal.centro.contains(EstadoJuego.idx(6, 4)), isTrue);
      expect(diagonal.centro.contains(EstadoJuego.idx(5, 3)), isFalse,
          reason: 'la diagonal no debe quedar mezclada con la horizontal');

      art.dirCol = 0;
      art.dirFila = -1;
      final vertical = j.zonaBombardeo(art, 4, 3);
      expect(vertical.centro.contains(EstadoJuego.idx(4, 3)), isTrue);
      expect(vertical.centro.contains(EstadoJuego.idx(5, 3)), isFalse,
          reason: 'la zona vertical no debe extenderse en horizontal');
    });

    test('rampa no aumenta habilidades con rango fijo', () {
      final j = partida(j1: [ClaseTanque.sembrador, ClaseTanque.artilleria, ClaseTanque.pesado]);
      final s = j.tanquePorId(1)!;
      s.col = 4;
      s.fila = 5;
      final rampa = Obstaculo(tipo: TipoObstaculo.rampa, col: 4, fila: 5);
      j.obstaculos.add(rampa);

      expect(j.casillasCampo(s).contains(EstadoJuego.idx(4, 1)), isTrue,
          reason: 'el campo sigue a rango fijo 4 aunque esté en rampa');
      expect(j.casillasCampo(s).contains(EstadoJuego.idx(4, 5)), isFalse,
          reason: 'no debe ganar +1 de alcance por estar en rampa');

      final a = j.tanquePorId(2)!;
      a.col = 4;
      a.fila = 9;
      a.dirCol = 0;
      a.dirFila = -1;
      expect(j.rangoDe(a).alcance.length, equals(13),
          reason: 'el disparo normal sí gana +1 sobre rampa');
    });
  });

  group('Soporte', () {
    EstadoJuego conSoporte() {
      final j = partida(j1: [ClaseTanque.soporte, ClaseTanque.zapador, ClaseTanque.pesado]);
      ubicar(j, 1, 4, 5); // Soporte
      ubicar(j, 2, 5, 5); // Zapador, pegado
      ubicar(j, 3, 4, 7); // Pesado, a 2 casillas
      return j;
    }

    test('Reparar: +30 HP y +10% del Armor máximo, no a sí mismo', () {
      final j = conSoporte();
      final a = j.tanquePorId(2)!;
      a.vida = a.clase.vida - 50;
      a.armor = 0;
      final r = j.aplicar(cmd(TipoComando.reparar, 1, tanque: 1, col: 5, fila: 5));
      expect(r.ok, isTrue, reason: r.texto);
      expect(a.vida, a.clase.vida - 20);
      expect(a.armor, (a.armorMaximo * EstadoJuego.armorReparacionPct).round().clamp(0, a.armorMaximo));
      // El Soporte ya gastó su ciclo; incluso con otro ciclo, sí mismo no vale
      expect(j.objetivosReparacion(j.tanquePorId(1)!).contains(EstadoJuego.idx(4, 5)), isFalse);
    });

    test('Reparar no pasa del HP máximo', () {
      final j = conSoporte();
      final a = j.tanquePorId(2)!;
      a.vida = a.clase.vida - 5;
      j.aplicar(cmd(TipoComando.reparar, 1, tanque: 1, col: 5, fila: 5));
      expect(a.vida, a.clase.vida);
    });

    test('Cable: jala al aliado a una casilla pegada al Soporte', () {
      final j = conSoporte();
      final r = j.aplicar(cmd(TipoComando.cable, 1,
          tanque: 1, aliado: 3, jalar: true, col: 4, fila: 6));
      expect(r.ok, isTrue, reason: r.texto);
      final p = j.tanquePorId(3)!;
      expect((p.col, p.fila), (4, 6));
    });

    test('Cable: el Soporte se acerca al aliado y cuenta como movido', () {
      final j = conSoporte();
      final r = j.aplicar(cmd(TipoComando.cable, 1,
          tanque: 1, aliado: 3, jalar: false, col: 4, fila: 6));
      expect(r.ok, isTrue, reason: r.texto);
      final s = j.tanquePorId(1)!;
      expect((s.col, s.fila), (4, 6));
      expect(j.movidosTurno.contains(1), isTrue);
    });

    test('Cable: un Pesado atrincherado no se puede jalar', () {
      final j = conSoporte();
      j.energia[1] = 6;
      expect(j.aplicar(cmd(TipoComando.trinchera, 1, tanque: 3)).ok, isTrue);
      final r = j.aplicar(cmd(TipoComando.cable, 1,
          tanque: 1, aliado: 3, jalar: true, col: 4, fila: 6));
      expect(r.ok, isFalse);
    });

    test('Cable: fuera de rango 2 no funciona', () {
      final j = conSoporte();
      ubicar(j, 3, 4, 8);
      final r = j.aplicar(cmd(TipoComando.cable, 1,
          tanque: 1, aliado: 3, jalar: true, col: 4, fila: 6));
      expect(r.ok, isFalse);
    });

    test('Pasiva: el aliado pegado gana +10 de Armor al empezar tu turno', () {
      final j = conSoporte();
      final a = j.tanquePorId(2)!;
      a.armor = 0;
      j.aplicar(cmd(TipoComando.terminarTurno, 1));
      j.aplicar(cmd(TipoComando.terminarTurno, 2));
      expect(a.armor, 10.clamp(0, a.armorMaximo));
    });

    test('Estación: una sola activa, cura al empezar tu turno y da descuento', () {
      final j = conSoporte();
      j.energia[1] = 8;
      final a = j.tanquePorId(2)!;
      a.vida = a.clase.vida - 50;
      expect(j.aplicar(cmd(TipoComando.estacion, 1, tanque: 1)).ok, isTrue);
      expect(j.estaciones.length, 1);
      j.aplicar(cmd(TipoComando.terminarTurno, 1));
      j.aplicar(cmd(TipoComando.terminarTurno, 2));
      expect(a.vida, a.clase.vida - 20);
      expect(j.conDescuento.contains(2), isTrue);
      expect(j.costoEfectivo(a, 2), 1);
      expect(j.costoEfectivo(a, 1), 1);
      expect(j.costoEfectivo(a, 4), 4); // las ultimates no tienen descuento
      expect(j.aplicar(cmd(TipoComando.estacion, 1, tanque: 1)).ok, isFalse,
          reason: 'ya hay una activa');
    });

    test('Estación: limpia estados negativos al crearla', () {
      final j = conSoporte();
      j.energia[1] = 4;
      j.aplicarEstado(j.tanquePorId(2)!, EstadoTanque.atascado);
      j.aplicar(cmd(TipoComando.estacion, 1, tanque: 1));
      expect(j.estaAtascado(j.tanquePorId(2)!), isFalse);
    });
  });
}
