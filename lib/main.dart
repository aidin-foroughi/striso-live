// Striso Live: the desktop companion for the Striso board.
//
// Command line:
//   --demo            start with the simulated board
//   --no-usb          never touch USB (smoke tests, screenshots)
//   --fake-save[=fail] Save to Striso goes through every step except the drive
//   --no-audio        no Through PC / Record (the audio library is not loaded)
//   --smoke=<s>       log a smoke line and quit after s seconds (with --hidden in the runner:
//                     the window stays minimized and off-screen)
//
// Every error goes to the console drawer and the log file; none opens a native dialog.

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:striso_audio/striso_audio.dart' show NativeAudioBackend;
import 'package:striso_core/striso_core.dart' show Transport;
import 'package:striso_usb/striso_usb.dart';

import 'src/app_log.dart';
import 'src/controller.dart';
import 'src/store.dart';
import 'src/theme.dart';
import 'src/ui/home.dart';
import 'src/win_close.dart';

/// libusb in the background isolate, started on first use.
class NativeUsbBackend implements UsbBackend {
  Future<UsbService>? _starting;
  UsbService? _svc;

  Future<UsbService> _service() => _starting ??= UsbService.start().then((s) {
    _svc = s;
    s.log.listen((l) => appLog.info('usb: $l'));
    return s;
  });

  @override
  Future<({bool present, String where})> probe() async {
    final r = await (await _service()).probe();
    return (present: r.present, where: r.where);
  }

  @override
  Transport transport() => _svc!.transport();

  @override
  Future<void> dispose() async => _svc?.dispose();
}

void _report(String what, Object error, StackTrace? st) {
  appLog.err('$what: $error');
  if (st != null) appLog.add(st.toString().split('\n').take(8).join('\n'), LogKind.err);
}

void main(List<String> args) {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    final home = appSupportDir();
    appLog.openFile('$home${Platform.pathSeparator}logs');
    FlutterError.onError = (d) {
      _report('app error', d.exception, d.stack);
      _controller?.showBanner('Striso Live hit an error: ${d.exceptionAsString()}. The console drawer has details.');
    };
    PlatformDispatcher.instance.onError = (e, st) {
      _report('uncaught', e, st);
      return true;
    };
    ErrorWidget.builder = (d) => Container(
      color: const Color(0xFF3A1F2A),
      padding: const EdgeInsets.all(8),
      child: Text('This panel hit an error: ${d.exceptionAsString()}', style: ui(12, color: const Color(0xFFFFD9D9))),
    );
    // Inter, bundled: its licence in the app's licence list
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(['Inter'], await rootBundle.loadString('assets/fonts/OFL.txt'));
    });
    final options = AppOptions.parse(args);
    appLog.info('Striso Live ${args.isEmpty ? '' : '(${args.join(' ')}) '}on ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    // the audio library is only loaded here; it opens nothing until Through PC or Record is on
    final audio = options.noAudio ? null : NativeAudioBackend.tryLoad();
    if (audio != null) {
      appLog.info('audio: engine ${audio.description}');
    } else if (!options.noAudio) {
      appLog.err('audio: engine missing: ${NativeAudioBackend.loadError}');
    }
    final ctl = AppController(
      options: options,
      store: Store('$home${Platform.pathSeparator}settings.json'),
      usb: options.noUsb ? null : NativeUsbBackend(),
      audioBackend: audio,
    );
    _controller = ctl;
    runApp(StrisoLiveApp(ctl));
    unawaited(ctl.start());
    final smoke = args.where((a) => a.startsWith('--smoke=')).map((a) => double.tryParse(a.substring(8))).firstOrNull;
    if (smoke != null) {
      Timer(Duration(milliseconds: (smoke * 1000).round()), () async {
        appLog.info(
          'smoke: ok after ${smoke}s, ${ctl.connected ? 'connected (${ctl.mode?.name})' : 'not connected'}, ${ctl.voices.length} voices, '
          'audio ${ctl.audio.state.name}',
        );
        // the same way out as closing the window: the exit handler lets go of the board
        if (!closeOwnWindow()) await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
      });
    }
  }, (e, st) => _report('uncaught', e, st));
}

AppController? _controller;

class StrisoLiveApp extends StatefulWidget {
  final AppController ctl;
  const StrisoLiveApp(this.ctl, {super.key});
  @override
  State<StrisoLiveApp> createState() => _StrisoLiveAppState();
}

class _StrisoLiveAppState extends State<StrisoLiveApp> {
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // give the board back before the window goes
    _life = AppLifecycleListener(
      onExitRequested: () async {
        await widget.ctl.shutdown();
        await appLog.close();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Striso Live', debugShowCheckedModeBanner: false, theme: strisoTheme(), home: HomePage(widget.ctl));
  }
}
