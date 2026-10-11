/// Obstáculos del mapa (GDD): muros bloquean paso y visión; manchas atascan; rampa da altura.
enum TipoObstaculo {
  sacos('Muro de sacos de arena', true),
  ladrillo('Muro de ladrillo', true),
  tinta('Mancha de tinta', false),
  cafe('Mancha de café', false),
  rampa('Rampa de altura', false);

  const TipoObstaculo(this.nombre, this.esMuro);

  final String nombre;
  final bool esMuro;

  /// Las manchas aplican el estado "Atascado".
  bool get atasca => this == tinta || this == cafe;
}

class Obstaculo {
  static const int hpMuro = 50;

  final TipoObstaculo tipo;
  final int col;
  final int fila;
  int hp;

  Obstaculo({required this.tipo, required this.col, required this.fila})
      : hp = tipo.esMuro ? hpMuro : 0;
}
