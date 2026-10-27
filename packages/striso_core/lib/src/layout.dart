// The Striso's keys as the firmware reports them (console StcG), and the app's picture of the
// board around them (the DCompose geometry of utils/dcompose.py, the control buttons, the plate).
//
// The StcG reply, lines ending in CRLF:
//   layout <keys> <buttons> <start note> flip=<0|1>
//   <n> <button> <c0> <c1> <name>        one line per key, n = key number 0..keys-1
//   layout end
// button: the button id (0..buttons-1) the live key stream reports; a button no key line names is
// not on the board. c0/c1: the physical coordinates, octaves and fifths from the key at 0 0. The
// start note is the MIDI note of 0 0 in 12-TET (62 = D4), so a key's 12-TET pitch is
// 12 * c0 + 7 * c1 above it. name: the firmware's 3 character key name (the one StcN uses). flip:
// the board's flipdir; the keys stay where they are, so the picture ignores it.

/// One key of the board, as StcG reports it, with its place in the picture.
class KeyInfo {
  /// The firmware's key number (0..60): the order of StcN and the per-key sensitivity list.
  final int n;

  /// The button id the key stream reports.
  final int id;

  /// Octaves and fifths from the key at 0 0.
  final int c0, c1;

  /// The firmware's key name, e.g. 'F_1', 'Gb1', 'D_3'.
  final String name;
  const KeyInfo({required this.n, required this.id, required this.c0, required this.c1, required this.name});

  /// Semitones above the start note in 12-TET.
  int get pitch => 12 * c0 + 7 * c1;

  /// A natural (no accidental in its spelling).
  bool get natural => spell(c1).acc == 0;

  /// The key's centre in mm, y up, origin at the key at 0 0.
  double get x => c1 * mmPerColumn;
  double get y => pitch * mmPerSemitone;
}

/// The board's keys as the firmware reports them (StcG).
class KeyLayout {
  /// The keys by key number.
  final List<KeyInfo> keys;

  /// Button ids are 0..buttons-1.
  final int buttons;

  /// The MIDI note of the key at 0 0 in 12-TET.
  final int startNote;

  /// The board's flipdir (the keys stay where they are).
  final bool flip;

  /// The reply as the board sent it (kept to show the picture before the board reports again).
  final List<String> lines;

  /// The keys in button id order, and their ids.
  final List<KeyInfo> boardKeys;
  final List<int> keyIds;
  final Map<int, KeyInfo> _byId;

  KeyLayout._(this.keys, this.buttons, this.startNote, this.flip, this.lines, this._byId)
    : boardKeys = List.unmodifiable([...keys]..sort((a, b) => a.id.compareTo(b.id))),
      keyIds = List.unmodifiable([for (final k in [...keys]..sort((a, b) => a.id.compareTo(b.id))) k.id]);

  /// The key on button [id], or null when the board has no key there.
  KeyInfo? operator [](int id) => _byId[id];

  /// The key on button [id]; throws when the board has no key there.
  KeyInfo keyInfo(int id) => _byId[id] ?? (throw ArgumentError.value(id, 'id', 'no key on this button'));

  /// The firmware's key number of button [id], or null.
  int? keyNumberOf(int id) => _byId[id]?.n;

  /// Semitones above [startNote] (12-TET).
  int pitchOf(int id) => keyInfo(id).pitch;

  /// Spelled pitch of a key on the line of fifths with C = 0 (harmony tpc), for a spelling shift.
  int keyTpc(int id, [int fifths = 0]) => keyInfo(id).c1 + 2 + fifths;

  /// Note name with scientific octave for a transposition (semitones) and spelling shift.
  NoteName noteName(int id, [int transpose = 0, int fifths = 0]) {
    final k = keyInfo(id);
    final s = spell(k.c1 + fifths);
    final midi = startNote + k.pitch + transpose;
    final natural = midi - s.acc;
    final octave = ((natural - _letterPc[s.letter]!) / 12).round() - 1;
    final text = '${s.letter}${s.accidental}';
    return NoteName(letter: s.letter, accidental: s.accidental, acc: s.acc, midi: midi, octave: octave, text: text, full: '$text$octave');
  }

  @override
  String toString() => 'KeyLayout(${keys.length} keys, $buttons buttons, start note $startNote${flip ? ', flipped' : ''})';
}

final _header = RegExp(r'^layout (\d+) (\d+) (\d+) flip=([01])$');
final _keyLine = RegExp(r'^(\d+) (\d+) (-?\d+) (-?\d+) (\S+)$');
const _end = 'layout end';

/// The reply's first line.
bool isKeyLayoutHeader(String line) => _header.hasMatch(line.trim());

/// A key line of the reply.
bool isKeyLayoutKey(String line) => _keyLine.hasMatch(line.trim());

/// The reply's last line.
bool isKeyLayoutEnd(String line) => line.trim() == _end;

/// The reply to StcG, or null unless it is all there: the header, a line for every key (numbers
/// 0..keys-1, each button once and below the button count) and the end.
KeyLayout? parseKeyLayout(List<String> lines) {
  final kept = <String>[];
  RegExpMatch? head;
  final keys = <int, KeyInfo>{}, byId = <int, KeyInfo>{};
  var ended = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (head == null) {
      head = _header.firstMatch(line);
      if (head != null) kept.add(line);
      continue;
    }
    if (line == _end) {
      kept.add(line);
      ended = true;
      break;
    }
    final m = _keyLine.firstMatch(line);
    if (m == null) return null;
    final k = KeyInfo(n: int.parse(m[1]!), id: int.parse(m[2]!), c0: int.parse(m[3]!), c1: int.parse(m[4]!), name: m[5]!);
    if (keys.containsKey(k.n) || byId.containsKey(k.id)) return null;
    keys[k.n] = k;
    byId[k.id] = k;
    kept.add(line);
  }
  if (head == null || !ended) return null;
  final count = int.parse(head[1]!), buttons = int.parse(head[2]!);
  if (keys.length != count || byId.keys.any((id) => id >= buttons)) return null;
  final byN = <KeyInfo>[];
  for (var n = 0; n < count; n++) {
    final k = keys[n];
    if (k == null) return null;
    byN.add(k);
  }
  return KeyLayout._(List.unmodifiable(byN), buttons, int.parse(head[3]!), head[4] == '1', List.unmodifiable(kept), byId);
}

// geometry in millimetres (dcompose.get_default: 8.5 mm per column, octave = 4.5356 columns)
const double mmPerColumn = 8.5;
const double mmPerSemitone = (4.5356 * 8.5) / 12;
const double keyRadius = 7.0;

const _letters = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
const _letterPc = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
const _accidentals = ['♭♭', '♭', '', '♯', '\u{1D12A}'];

class Spelling {
  final String letter, accidental;
  final int acc;
  const Spelling(this.letter, this.acc, this.accidental);
}

/// Note spelling from the position on the line of fifths relative to D (dcompose.latin).
Spelling spell(int c1v) {
  final acc = (c1v / 7).round();
  return Spelling(_letters[c1v - acc * 7 + 3], acc, _accidentals[acc + 2]);
}

class NoteName {
  final String letter, accidental, text, full;
  final int acc, midi, octave;
  const NoteName({
    required this.letter,
    required this.accidental,
    required this.acc,
    required this.midi,
    required this.octave,
    required this.text,
    required this.full,
  });
}

enum ControlShape { ring, up, down, square }

class ControlButton {
  final int id;
  final String name;
  final ControlShape shape;
  final double x, y;
  const ControlButton(this.id, this.name, this.shape, this.x, this.y);
}

/// Control buttons and the LED at the left, from doc/strisoboard-reference.png (mm, same frame).
const List<ControlButton> controls = [
  ControlButton(0, 'Glissando', ControlShape.ring, -89, 31.9),
  ControlButton(1, 'Octave up', ControlShape.up, -89, 1.0),
  ControlButton(2, 'Octave down', ControlShape.down, -89, -14.0),
  ControlButton(3, 'Settings', ControlShape.square, -89, -46.0),
];
const ledPosition = (x: -89.0, y: 53.0);

/// The plate outline that holds everything (mm).
const plate = (x0: -104.0, x1: 79.0, y0: -80.0, y1: 80.0, radius: 9.0);
