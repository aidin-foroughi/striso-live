// The board's console for the bench: the latency marker (Stcl1), the echo (Stcl0), the USB audio
// counters (StcU) and ring target (Stct), the version (V). The hardware console talks to the board
// through striso_usb's worker isolate, whose transfers carry their own timestamps; every time here
// is on the audio library's clock (sa_clock_us), through a measured offset.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:typed_data';

import 'package:striso_core/striso_core.dart';
import 'package:striso_usb/striso_usb.dart';

/// "usb audio marker 7: frame 1234 index 0 level 101 target 96, bus 2345 us after rx (rx frame
/// 1232), right 32 frames -20 dBFS 24 bit" (usb_audio.c, usb_audio_marker_poll).
class MarkerReply {
  final int seq;
  final String status; // 'sent', 'lost', 'not streaming', 'busy'
  final int? frame, index, level, target, busUs, rxFrame, frames, bits;
  const MarkerReply(this.seq, this.status, {this.frame, this.index, this.level, this.target, this.busUs, this.rxFrame, this.frames, this.bits});
  bool get sent => status == 'sent';

  static final _sent = RegExp(
    r'usb audio marker (\d+): frame (\d+) index (\d+) level (-?\d+) target (\d+), bus (\d+) us after rx \(rx frame (\d+)\), right (\d+) frames -20 dBFS (\d+) bit',
  );
  static final _other = RegExp(r'usb audio marker ?(\d+)?: (lost|not streaming|busy)');

  static MarkerReply? parse(String line) {
    final m = _sent.firstMatch(line);
    if (m != null) {
      int g(int i) => int.parse(m.group(i)!);
      return MarkerReply(g(1), 'sent', frame: g(2), index: g(3), level: g(4), target: g(5), busUs: g(6), rxFrame: g(7), frames: g(8), bits: g(9));
    }
    final o = _other.firstMatch(line);
    if (o != null) return MarkerReply(int.tryParse(o.group(1) ?? '') ?? 0, o.group(2)!);
    return null;
  }
}

/// "usb audio echo: held 1234 us": from the command's OUT packet to the SOF that flushes the reply.
int? parseEcho(String line) {
  final m = RegExp(r'usb audio echo: held (\d+) us').firstMatch(line);
  return m == null ? null : int.parse(m.group(1)!);
}

/// A command and its reply, with times on the audio clock: [sentUs] the worker submitted the
/// OUT transfer, [writtenUs] it completed, [replyUs] the reply's last line arrived in the worker.
class Exchange<T> {
  final T? reply;
  final int sentUs, writtenUs, replyUs;
  const Exchange(this.reply, this.sentUs, this.writtenUs, this.replyUs);
  int get rttUs => replyUs - sentUs;
}

abstract class BoardConsole {
  String get label;
  Future<String?> version();
  Future<Exchange<int>> echo();
  Future<Exchange<MarkerReply>> marker();
  Future<UsbAudioStats?> usbStats();
  Future<int?> setTarget(int frames);
  Future<void> close();
}

Uint8List _cmd(String s) => Uint8List.fromList(ascii.encode('Stc$s'));

/// The real board over USB (the bulk console, interface 2: only one program can hold it).
class UsbConsole implements BoardConsole {
  final UsbService _service;
  final LibusbTransport _t;

  /// sa_clock_us - Timeline.now.
  final int clockOffsetUs;
  final _lines = StreamController<(String, int)>.broadcast(sync: true);
  final _buf = BytesBuilder();
  StreamSubscription<(Uint8List, int)>? _sub;

  UsbConsole._(this._service, this._t, this.clockOffsetUs);

  @override
  String get label => _t.label;

  /// Opens the console, retrying a busy board every [retryEvery] until [giveUpAfter] (another
  /// program may hold it for a moment); null when there is no board or it stays busy.
  static Future<UsbConsole?> open({required int clockOffsetUs, String? libusb, Duration giveUpAfter = const Duration(seconds: 45), Duration retryEvery = const Duration(seconds: 3), void Function(String)? log}) async {
    final service = await UsbService.start(libusbPath: libusb);
    final sw = Stopwatch()..start();
    while (true) {
      final t = service.transport();
      try {
        await t.open();
        final c = UsbConsole._(service, t, clockOffsetUs);
        c._sub = t.timedData.listen(c._onData);
        await t.write(Cmd.streamOff()); // nothing but replies from here
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return c;
      } on UsbError catch (e) {
        if (e.code == UsbErrorCode.busy && sw.elapsed < giveUpAfter) {
          log?.call('the board is busy (${e.message}): again in ${retryEvery.inSeconds} s');
          await Future<void>.delayed(retryEvery);
          continue;
        }
        log?.call('no console: ${e.message}');
        await service.dispose();
        return null;
      }
    }
  }

  void _onData((Uint8List, int) d) {
    final (bytes, at) = d;
    for (final b in bytes) {
      if (b == 10) {
        final s = latin1.decode(_buf.takeBytes(), allowInvalid: true).trim();
        if (s.isNotEmpty) _lines.add((s, at + clockOffsetUs));
      } else if (b != 13 && b >= 32 && b < 127) {
        _buf.addByte(b);
      }
    }
  }

  /// Sends [bytes] and collects lines until [take] says done (true) or [timeout].
  Future<Exchange<T>> _ask<T>(Uint8List bytes, T? Function(String line) take, {Duration timeout = const Duration(milliseconds: 600)}) async {
    final done = Completer<(T?, int)>();
    final sub = _lines.stream.listen((l) {
      final v = take(l.$1);
      if (v != null && !done.isCompleted) done.complete((v, l.$2));
    });
    final (sub0, w0) = await _t.writeTimed(bytes);
    final r = await done.future.timeout(timeout, onTimeout: () => (null, Timeline.now + clockOffsetUs));
    await sub.cancel();
    return Exchange<T>(r.$1, sub0 + clockOffsetUs, w0 + clockOffsetUs, r.$2);
  }

  @override
  Future<String?> version() async {
    final r = await _ask<String>(Cmd.version(), (l) => RegExp(r'\d{4}-\d\d-\d\d_v[\w.\-]+').firstMatch(l)?.group(0));
    // V turns the stream off and flushes the queue: fine here
    return r.reply;
  }

  @override
  Future<Exchange<int>> echo() => _ask<int>(_cmd('l0'), parseEcho, timeout: const Duration(milliseconds: 300));

  @override
  Future<Exchange<MarkerReply>> marker() => _ask<MarkerReply>(_cmd('l1'), MarkerReply.parse, timeout: const Duration(milliseconds: 400));

  @override
  Future<UsbAudioStats?> usbStats() async {
    final lines = <String>[];
    final r = await _ask<bool>(Cmd.usbAudio(), (l) {
      if (!usbAudioLine.hasMatch(l)) return null;
      lines.add(l);
      return isLastUsbAudioLine(l) ? true : null;
    });
    if (r.reply != true && lines.isEmpty) return null;
    return parseUsbAudioStats(lines);
  }

  @override
  Future<int?> setTarget(int frames) async => (await _ask<int>(Cmd.usbAudioTarget(frames), parseUsbAudioTarget)).reply;

  /// The voices ('v'): (index, name, current).
  Future<List<(int, String, bool)>> voices() async {
    final out = <(int, String, bool)>[];
    final re = RegExp(r'^([ *]?)\s*(\d+) (\S.*)$');
    await _ask<bool>(Cmd.voices(), (l) {
      final m = re.firstMatch(l);
      if (m != null && !l.startsWith('usb audio')) out.add((int.parse(m.group(2)!), m.group(3)!, m.group(1) == '*'));
      return null;
    }, timeout: const Duration(milliseconds: 400));
    return out;
  }

  /// Selects voice [n] (StcW, any entry): its name, or null.
  Future<String?> selectVoice(int n) async =>
      (await _ask<String>(selectVoiceCommand(n), (l) => RegExp(r'^voice \d+ (.+)$').firstMatch(l)?.group(1), timeout: const Duration(milliseconds: 800))).reply;

  /// The synth's DSP load since the last call ('L'): (blocks, avg, peak, budget cycles).
  Future<({int blocks, int avg, int peak, int budget})?> synthLoad() async {
    final r = await _ask<RegExpMatch>(Cmd.load(), (l) => RegExp(r'synth blocks (\d+) avg (\d+) peak (\d+) budget (\d+)').firstMatch(l));
    final m = r.reply;
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return (blocks: g(1), avg: g(2), peak: g(3), budget: g(4));
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    try {
      await _t.close();
    } catch (_) {}
    await _service.dispose();
    await _lines.close();
  }
}

/// A board for runs without hardware: deterministic replies from a fixed model (the bench's own
/// tests and CI). It cannot put a marker into a real input, so the simulated usb-in also builds
/// the capture side (see sim.dart).
class SimConsole implements BoardConsole {
  int _seq = 0, target = 96;
  int _now = 0;
  final int Function() clock;
  SimConsole(this.clock);

  @override
  String get label => 'simulated board';

  int _t() => _now = clock() > _now ? clock() : _now + 1;

  @override
  Future<String?> version() async => 'sim_v0';

  @override
  Future<Exchange<int>> echo() async {
    final s = _t();
    // 150 us out, held 1450 us, 150 us back
    return Exchange(1450, s, s + 150, s + 1750);
  }

  @override
  Future<Exchange<MarkerReply>> marker() async {
    final s = _t();
    _seq++;
    return Exchange(MarkerReply(_seq, 'sent', frame: _seq * 7 % 2048, index: 0, level: 100, target: target, busUs: 1900, rxFrame: 0, frames: 32, bits: 24), s, s + 150, s + 3700);
  }

  @override
  Future<UsbAudioStats?> usbStats() async => parseUsbAudioStats([
    'usb audio (UAC2): streaming 48000 Hz 24 bit (alt 1), source synth',
    'since last U: packets sent 2000 missed 0 (host skipped 0, flushed early 0); built 2000 (47:2 48:1996 49:2)',
    'ring: level 100 now, 96 filtered, 70..128 before packets (target $target = ${target * 1000 ~/ 48} us, of 512)',
    'faults: underruns 0 overruns 0 primes 0 (silent packets 0), fast starts 0',
    'frames: not ready at SOF 0; SOF late (>1.1 ms) 0 lost 0, max interval 1010 us',
    'cpu: usb audio ISR hooks 9000000 cycles = 0.22% of 2000 ms',
  ]);

  @override
  Future<int?> setTarget(int frames) async => target = frames == 0 ? target : frames.clamp(49, 256);

  @override
  Future<void> close() async {}
}
