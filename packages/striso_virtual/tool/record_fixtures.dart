// Records the firmware's console replies that striso_core's parser tests read
// (packages/striso_core/test/fixtures/): the key layout (StcG), the settings layout (StcX), the
// config Save to Striso writes (Stcc) and the tuning reply (StcN) of every settings-card tuning,
// from a virtual board (the firmware's own code, striso_virtual).
// Each file names the firmware it came from; run it again after a firmware change that changes
// these replies:
//
//   STRISO_VIRTUAL_LIB=.../striso_virtual.dll dart run tool/record_fixtures.dart [out dir]
//
// (or STRISO_FW_DIR=<firmware checkout>). The board runs in virtual time: a command is written,
// a second of board time passes, what the console sent is its reply.
import 'dart:io';
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:striso_virtual/striso_virtual.dart';

/// The reply lines to [cmd]: written to the console, a second of board time, what came back.
List<String> ask(VirtualBoard b, List<int> cmd) {
  b.consoleRead();
  if (b.consoleWrite(cmd) != cmd.length) throw StateError('the console did not take ${String.fromCharCodes(cmd)}');
  final out = BytesBuilder();
  for (var i = 0; i < 40; i++) {
    b.advanceMs(25);
    final r = b.consoleRead();
    if (r == null) throw StateError('the board left the bus');
    out.add(r);
  }
  return String.fromCharCodes(out.takeBytes()).split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
}

/// A command as the firmware's transcripts write it: printable bytes as they are, the rest \xNN.
String shown(List<int> cmd) => cmd.map((c) => c >= 0x20 && c < 0x7f && c != 0x5c ? String.fromCharCode(c) : '\\x${c.toRadixString(16).padLeft(2, '0').toUpperCase()}').join();

class Fixture {
  final String about;
  final buf = StringBuffer();
  Fixture(this.about);

  /// A section: `[name] > command`, then the reply lines.
  void section(String name, List<int> cmd, List<String> reply) {
    if (reply.isEmpty) throw StateError('no reply to $name');
    buf.writeln('[$name] > ${shown(cmd)}');
    reply.forEach(buf.writeln);
  }

  void write(String path, String firmware) {
    File(path).writeAsStringSync(
      '# $about\n'
      '# Recorded from the virtual board (striso-control-firmware\'s striso_virtual) by\n'
      '# packages/striso_virtual/tool/record_fixtures.dart; do not edit, record again.\n'
      '# firmware: $firmware\n'
      '# Sections: [name] > the command sent, then the board\'s reply lines.\n'
      '$buf',
    );
    stdout.writeln('wrote $path');
  }
}

void main(List<String> args) {
  final out = args.isNotEmpty ? args.first : '../striso_core/test/fixtures';
  final b = VirtualBoard();
  try {
    final fw = b.firmwareVersion;

    final keyLayout = Fixture("The key layout (StcG): every key's number, button id, coordinates and name.");
    final g = commandChar('G');
    keyLayout.section('G', g, ask(b, g));
    keyLayout.write('$out/key_layout.txt', fw);

    final layout = Fixture('The settings layout (StcX) of a board with the factory settings.');
    final x = commandChar('X');
    layout.section('X', x, ask(b, x));
    layout.write('$out/settings_layout.txt', fw);

    final config = Fixture('The config Save to Striso writes (Stcc) of a board with the factory settings.');
    final cc = commandChar('c');
    config.section('c', cc, ask(b, cc));
    config.write('$out/config_uf2.txt', fw);

    // the settings card's tuning keys, tuning 0..8 (their StcX titles say which is which)
    final tunings = Fixture('The tuning reply (StcN) for each settings-card tuning, chosen with its settings key (StcK); then 12-TET with the fine dial at -31.25 cents.');
    const keys = [34, 36, 38, 23, 25, 27, 29, 31, 33];
    for (var n = 0; n < keys.length; n++) {
      final k = settingsKeyCommand(keys[n]);
      final r = ask(b, k);
      if (r.join() != 'K ok ${keys[n]}') throw StateError('StcK ${keys[n]}: $r');
      tunings.section('tuning $n', Cmd.tuning(), ask(b, Cmd.tuning()));
    }
    final k0 = settingsKeyCommand(keys[0]);
    if (ask(b, k0).join() != 'K ok ${keys[0]}') throw StateError('StcK ${keys[0]}');
    final lowered = ask(b, dialSetCommand(6, -31.25));
    if (lowered.join() != 'T fine -31.25') throw StateError('the fine dial: $lowered');
    tunings.section('tuning 0 fine -31.25', Cmd.tuning(), ask(b, Cmd.tuning()));
    tunings.write('$out/tunings.txt', fw);
  } finally {
    b.dispose();
  }
}
