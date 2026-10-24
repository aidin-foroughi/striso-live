// The active instrument, as the UI and the domain logic see it (docs/architecture.md): the
// console protocol (StrisoClient), what plays it by hand, where Save writes, and when it is gone.
// The Striso over USB and the virtual Striso implement it; nothing above this knows which.

import 'dart:async';

import 'package:striso_core/striso_core.dart';

import 'session_machine.dart';

abstract class Board {
  Mode get mode;

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
  String get label => 'Striso';

  @override
  Future<void> close() async {
    try {
      await client.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

/// A board on a transport the caller owns (tests, the Dart mock): Striso or Virtual by [mode].
class TransportBoard extends Board {
  @override
  final Mode mode;
  @override
  final String label;
  @override
  final StrisoClient client;
  @override
  final PlayableBoard? hand;
  TransportBoard(this.mode, Transport t, {this.label = 'Striso', this.hand}) : client = StrisoClient(t);

  @override
  Future<void> close() async {
    try {
      await client.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
