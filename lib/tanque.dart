/// Clases de tanque con las estadísticas del GDD.
class ClaseTanque {
  static const pesado = ClaseTanque(
    nombre: 'Pesado',
    simbolo: '⬢',
    vida: 350,
    armor: 50,
    dano: 45,
    movimiento: 2,
    rango: 3,
    costoTiro: 2,
  );
  static const zapador = ClaseTanque(
    nombre: 'Zapador',
    simbolo: '⚒️',
    vida: 240,
    armor: 30,
    dano: 30,
    movimiento: 2,
    rango: 3,
    costoTiro: 1,
  );
  static const soporte = ClaseTanque(
    nombre: 'Soporte',
    simbolo: '✚',
    vida: 200,
    armor: 20,
    dano: 20,
    movimiento: 2,
    rango: 3,
    costoTiro: 1,
  );
  static const sembrador = ClaseTanque(
    nombre: 'Sembrador',
    simbolo: '💣',
    vida: 190,
    armor: 20,
    dano: 35,
    movimiento: 3,
    rango: 2,
    costoTiro: 1,
  );
  static const ligero = ClaseTanque(
    nombre: 'Ligero',
    simbolo: '▲',
    vida: 180,
    armor: 15,
    dano: 40,
    movimiento: 3,
    rango: 2,
    costoTiro: 1,
  );
  static const artilleria = ClaseTanque(
    nombre: 'Artillería',
    simbolo: '⬦',
    vida: 110,
    armor: 0,
    dano: 75,
    movimiento: 2,
    rango: 4,
    costoTiro: 2,
  );

  static const List<ClaseTanque> values = [
    pesado,
    zapador,
    soporte,
    sembrador,
    ligero,
    artilleria,
  ];

  final String nombre;
  final String simbolo;
  final int vida;
  final int armor;
  final int dano;
  final int movimiento;
  final int rango;
  final int costoTiro;

  const ClaseTanque({
    required this.nombre,
    required this.simbolo,
    required this.vida,
    required this.armor,
    required this.dano,
    required this.movimiento,
    required this.rango,
    required this.costoTiro,
  });
}

const List<ClaseTanque> clasesTanque = ClaseTanque.values;

/// Un tanque puesto en el tablero.
class Tanque {
  final int id;
  final ClaseTanque clase;
  final int jugador; // 0 = J1, 1 = J2
  int col;
  int fila;
  int vida;
  int armor; // absorbe el daño antes que la vida
  int armorExtra = 0; // parte temporal del armor (Trinchera del Pesado)
  int armorBono = 0; // Armor máximo extra (Sacrificio del Comandante)
  int dirCol = 0; // hacia dónde mira (por defecto, hacia el rival)
  int dirFila;

  int get armorMaximo => clase.armor + armorBono;
  bool movido = false;
  bool disparo = false;

  Tanque({
    required this.id,
    required this.clase,
    required this.jugador,
    required this.col,
    required this.fila,
  })  : vida = clase.vida,
        armor = clase.armor,
        dirFila = jugador == 1 ? -1 : 1;
}
