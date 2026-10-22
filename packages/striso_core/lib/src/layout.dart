// Striso board key layout, from the firmware's button coordinates (synth_control.cpp c0_dis/c1_dis)
// and the DCompose geometry of utils/dcompose.py. Port of tools/app/js/layout.js.
//
// Button ids 0..67 are 4 rows of 17 columns; row 3 has only 10 keys (button_read.c disables
// 52 54 57 59 61 64 66). c0 counts octaves, c1 fifths from D (start note 62 = D4). Columns run
// Gb Db Ab Eb Bb F C G D A E B F# C# G# D# A# (c1 = -8..8), and a key's height is its pitch.

const List<int> c0 = [
  6, 5, 5, 4, 4, 3, 2, 2, 1, 1, 0, 0, -1, -2, -2, -3, -3,
  5, 4, 4, 3, 3, 2, 1, 1, 0, 0, -1, -1, -2, -3, -3, -4, -4,
  4, 3, 3, 2, 2, 1, 0, 0, -1, -1, -2, -2, -3, -4, -4, -5, -5,
  3, 2, 2, 1, 1, 0, -1, -1, -2, -2, -3, -3, -4, -5, -5, -6, -6,
];
final List<int> c1 = [for (var r = 0; r < 4; r++) for (var c = -8; c <= 8; c++) c];

const Set<int> missingButtons = {52, 54, 57, 59, 61, 64, 66};
const int buttonCount = 68;
final List<int> keyIds = [for (var id = 0; id < buttonCount; id++) if (!missingButtons.contains(id)) id];

const int startNote = 62; // D4, synth_control.cpp start_note_offset

/// Firmware key numbers (config_store.c button_number_map): key n (0..60) is button id map[n];
/// the per-key sensitivity list (console 'k', target 3) is in key-number order.
const List<int> buttonNumberMap = [
  56, 51, 63, 58, 53, 65, 60, 55, 67, 62, 40, 35, 47, 42, 37, 49, 44,
  39, 34, 46, 41, 36, 48, 43, 38, 50, 45, 23, 18, 30, 25, 20, 32, 27,
  22, 17, 29, 24, 19, 31, 26, 21, 33, 28, 6, 1, 13, 8, 3, 15, 10,
  5, 0, 12, 7, 2, 14, 9, 4, 16, 11,
];
final Map<int, int> keyNumberOf = {for (var n = 0; n < buttonNumberMap.length; n++) buttonNumberMap[n]: n};

const _fwNoteNames = 'C_DbC#D_EbD#E_F_GbF#G_AbG#A_BbA#B_';

/// The firmware's 3 character key names (put_button_name), e.g. 'F_1', 'Gb1', 'C_3'.
String firmwareKeyName(int n) {
  final note = (n + 7) % 17, octave = (n + 7) ~/ 17;
  return '${_fwNoteNames.substring(note * 2, note * 2 + 2)}${1 + octave}';
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

/// Semitones above [startNote] (12-TET).
int pitchOf(int id) => 12 * c0[id] + 7 * c1[id];

/// Spelled pitch of a key on the line of fifths with C = 0 (harmony tpc), for a spelling shift.
int keyTpc(int id, [int fifths = 0]) => c1[id] + 2 + fifths;

class NoteName {
  final String letter, accidental, text, full;
  final int acc, midi, octave;
  const NoteName({required this.letter, required this.accidental, required this.acc, required this.midi, required this.octave, required this.text, required this.full});
}

/// Note name with scientific octave for a transposition (semitones) and spelling shift.
NoteName noteName(int id, [int transpose = 0, int fifths = 0]) {
  final s = spell(c1[id] + fifths);
  final midi = startNote + pitchOf(id) + transpose;
  final natural = midi - s.acc;
  final octave = ((natural - _letterPc[s.letter]!) / 12).round() - 1;
  final text = '${s.letter}${s.accidental}';
  return NoteName(letter: s.letter, accidental: s.accidental, acc: s.acc, midi: midi, octave: octave, text: text, full: '$text$octave');
}

class KeyInfo {
  final int id, row, col, c0v, c1v, pitch;
  final bool natural;
  final double x, y; // mm, y up, origin at D4 (button 25)
  const KeyInfo(this.id, this.row, this.col, this.c0v, this.c1v, this.pitch, this.natural, this.x, this.y);
}

KeyInfo keyInfo(int id) => KeyInfo(
      id, id ~/ 17, id % 17, c0[id], c1[id], pitchOf(id), spell(c1[id]).acc == 0,
      c1[id] * mmPerColumn, pitchOf(id) * mmPerSemitone,
    );

final List<KeyInfo> boardKeys = [for (final id in keyIds) keyInfo(id)];

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
