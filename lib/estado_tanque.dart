/// Estados que puede tener un tanque (efectos temporales sobre la pieza).
///
/// Solo [atascado] tiene lógica por ahora. Los demás ya están nombrados
/// porque el GDD los menciona (Operación Trinchera y la Estación de
/// Reabastecimiento "limpian humo, tinta, anclaje y fuego"), pero todavía
/// ninguna habilidad los aplica.
enum EstadoTanque {
  /// Mancha de tinta (o mina del Sembrador): pierde todo el movimiento
  /// restante de su turno. Se quita al terminar el turno de su dueño.
  atascado(
    'Atascado',
    'No puede moverse hasta que termine su turno',
    negativo: true,
  ),

  /// Reservado: anclaje (Estación de Reabastecimiento lo limpia).
  anclado('Anclado', 'Reservado, sin efecto todavía', negativo: true),

  /// Reservado: humo.
  humo('Humo', 'Reservado, sin efecto todavía', negativo: true),

  /// Reservado: fuego aplicado al tanque (hoy el fuego de la Munición
  /// Incendiaria vive en la casilla, no en el tanque).
  quemado('Quemado', 'Reservado, sin efecto todavía', negativo: true);

  final String nombre;
  final String descripcion;

  /// Los estados negativos son los que limpian Operación Trinchera
  /// y la Estación de Reabastecimiento.
  final bool negativo;

  const EstadoTanque(this.nombre, this.descripcion, {required this.negativo});
}
