// The active instrument, as the UI and the domain logic see it (docs/architecture.md): the
// console protocol (StrisoClient), what it can do (BoardCapabilities), what plays it by hand,
// where Save writes, and when it is gone. The Striso over USB and the virtual Striso implement it;
// nothing above this asks which one plays: it asks the capabilities.

import 'dart:async';

import 'package:striso_core/striso_core.dart';

import 'session_machine.dart';

/// What the board that plays can do, and how the app names it. The Striso's board and Virtual's
/// each fill it in.
class BoardCapabilities {
  /// In a sentence: "the Striso", "Virtual"; [short] on a button: "Striso", "Virtual".
  final String name, short;

  /// Next to the sound's name (null: none): "VIRTUAL".
  final String? tag;

  /// A device on this computer's USB: it can be unplugged and comes back by itself, its USB audio
  /// is Through PC's input, its USB audio statistics are read.
  final bool usb;

  /// The app starts it again at once, so an engine put on a slot or erased takes effect now (else
  /// at its next power-up).
  final bool restarts;

  /// This computer's MIDI controllers play it (its own USB-MIDI input): the first time it plays,
  /// every input is chosen.
  final bool midiIn;

  /// Its settings are kept on this computer: Save writes its own update drive, then the flash is
  /// kept.
  final bool keptHere;

  /// The problem when its firmware is too old, before "(found …)".
  final String outdated;

  const BoardCapabilities({
    required this.name,
    required this.short,
    this.tag,
    required this.usb,
    required this.restarts,
    required this.midiIn,
    required this.keptHere,
    required this.outdated,
  });

  static const striso = BoardCapabilities(
    name: 'the Striso',
    short: 'Striso',
    usb: true,
    restarts: false,
    midiIn: false,
    keptHere: false,
    outdated: 'This Striso needs a firmware update to work with Striso Live',
  );

  static const virtual = BoardCapabilities(
    name: 'Virtual',
    short: 'Virtual',
    tag: 'VIRTUAL',
    usb: false,
    restarts: true,
    midiIn: true,
    keptHere: true,
    outdated: 'This build is too old for Striso Live',
  );
}

abstract class Board {
  Mode get mode;

  BoardCapabilities get caps;

  /// For the status and the log: "Striso", "Virtual Striso (2026-10-24 v2.2.4-80)".
  String get label;

  /// The console protocol: version, lists, voice select, parameters, K, N, X, Y, y, load.
  StrisoClient get client;

  /// The board view plays it by hand (the virtual Striso), or null.
  PlayableBoard? get hand => null;

  /// Where Save to Striso finds the bootloader's drive: null for the computer's drives.
  List<String>? get saveRoots => null;

  /// Opens the console; throws a UsbError when it cannot.
  Future<void> open() => client.connect();

  /// Stream off, the console released. Idempotent.
  Future<void> close();
}

/// The Striso over its USB console.
class StrisoBoard extends Board {
  @override
  final StrisoClient client;
  StrisoBoard(Transport t) : client = StrisoClient(t);

  @override
  Mode get mode => Mode.striso;
  @override
  BoardCapabilities get caps => BoardCapabilities.striso;
  @override
  String get label => 'Striso';

  @override
  Future<void> close() async {
    try {
      await client.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
