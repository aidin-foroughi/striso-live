// A board the app can play by hand (the board view in Demo): the Dart mock board, or the virtual
// board (striso_virtual) that runs the firmware's own code.

abstract class PlayableBoard {
  /// Key [id] (0..67) down or still down: pressure 0..1, tilt -1..1, a strike velocity 0..1.
  void press(int id, {double pres = 0.5, double x = 0, double y = 0, double strike = 0});

  /// Key [id] up, with a lift velocity.
  void release(int id, [double lift = 0.3]);

  /// An aux control (Idc.*) down or up.
  void control(int id, bool down);
}
