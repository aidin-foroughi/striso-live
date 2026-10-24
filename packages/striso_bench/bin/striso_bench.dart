// The Striso's USB audio measured headlessly: see lib/src/cli.dart for the commands.
import 'dart:io';

import 'package:striso_bench/src/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  // the USB worker isolate and the audio library are gone by now; exit at once
  exit(code);
}
