// Striso client over a transport: serialized text commands with reply collection, the binary key
// stream, throttled and coalesced parameter writes, a stream watchdog. Port of js/client.js.

import 'dart:async';
import 'dart:typed_data';

import 'board_state.dart';
import 'protocol.dart';
import 'transport.dart';
import 'tuning.dart';
import 'usb_audio_stats.dart';

const _paramIntervalMs = 16; // at most ~60 writes per second per parameter
const _streamSilenceMs = 3000;

/// What a collector says about a line: not mine, mine and more to come, or mine and done.
enum Take { no, more, done }

typedef Collector = Take Function(String line, Map<String, Object?> state);

class Reply {
  final List<String> lines;
  final Map<String, Object?> state;
  final bool timedOut;
  const Reply(this.lines, this.state, this.timedOut);
}

class _Request {
  final Uint8List bytes;
  final Collector collect;
  final Duration timeout, idle;
  final completer = Completer<Reply>();
  final lines = <String>[];
  final state = <String, Object?>{};
  Timer? timer, idleTimer;
  _Request(this.bytes, this.collect, this.timeout, this.idle);
}

class ParamList {
  final int target;
  final String name;
  final int count;
  final List<Param> params;
  final bool complete;
  const ParamList(this.target, this.name, this.count, this.params, this.complete);
}

class ClientDiagnostics {
  final ParserStats parser;
  final int rxBytes, restarts, queued;
  final bool streaming;
  final Duration? sinceMessage;
  const ClientDiagnostics(this.parser, this.rxBytes, this.streaming, this.restarts, this.sinceMessage, this.queued);
}

typedef StreamHandler = void Function(int src, int id, Int32List values, int count);

class StrisoClient {
  final Transport transport;
  late final StreamParser parser;
  StreamHandler? onStream;
  void Function(String label)? trace;
  final _textController = StreamController<String>.broadcast();
  final _qerrController = StreamController<({int target, int index})>.broadcast();
  final _closedController = StreamController<UsbError?>.broadcast();
  final _restreamController = StreamController<int>.broadcast();
  bool open = false;
  bool streaming = false;
  bool _ignoreText = false;
  final _queue = <_Request>[];
  _Request? _current;
  Future<void> _writeChain = Future.value();
  int _inFlight = 0;
  final _dirty = <int, ParamWrite>{};
  final _lastSent = <int, int>{};
  Timer? _flushTimer, _watchdog;
  int rxBytes = 0, sentParams = 0, restarts = 0;
  final _clock = Stopwatch()..start();
  int _lastMessageMs = -1, _lastBytesMs = -1, _streamSentMs = -1;
  StreamSubscription<Uint8List>? _sub;

  StrisoClient(this.transport) {
    parser = StreamParser(onMessage: _onMessage, onLine: _onLine);
  }

  /// Unsolicited text lines from the board (not replies to a request).
  Stream<String> get text => _textController.stream;
  Stream<({int target, int index})> get qErrors => _qerrController.stream;

  /// The connection ended: the reason (null after [disconnect]).
  Stream<UsbError?> get closed => _closedController.stream;
  Stream<int> get restreams => _restreamController.stream;

  int get _now => _clock.elapsedMilliseconds;

  Future<void> connect() async {
    await transport.open();
    open = true;
    _sub = transport.data.listen((bytes) {
      if (rxBytes == 0) trace?.call('first bytes from the board');
      rxBytes += bytes.length;
      _lastBytesMs = _now;
      parser.push(bytes);
    });
    transport.lost.then((reason) => _closed(reason));
    // whatever was queued before we came (an old stream, a half line) is dropped
    _ignoreText = true;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _ignoreText = false;
    parser.reset();
  }

  Future<void> disconnect() async {
    if (!open) return;
    open = false;
    _failPending();
    _flushTimer?.cancel();
    _watchdog?.cancel();
    await _writeChain.catchError((_) {});
    await transport.close();
    await _sub?.cancel();
    _closedController.add(null);
  }

  void _closed(UsbError reason) {
    if (!open) return;
    open = false;
    _failPending();
    _flushTimer?.cancel();
    _watchdog?.cancel();
    _sub?.cancel();
    _closedController.add(reason);
  }

  // writes, in order ------------------------------------------------------------------------------

  Future<void> _write(Uint8List bytes) {
    _inFlight++;
    final f = _writeChain.then((_) => open ? transport.write(bytes) : null);
    _writeChain = f.catchError((_) {}).whenComplete(() => _inFlight--);
    return f;
  }

  // text commands: one at a time, the reply lines go to the command's collector ---------------------

  Future<Reply> request(Uint8List bytes, Collector collect, {Duration timeout = const Duration(milliseconds: 600), Duration idle = Duration.zero}) {
    final r = _Request(bytes, collect, timeout, idle);
    _queue.add(r);
    _pump();
    return r.completer.future;
  }

  void _pump() {
    if (_current != null || _queue.isEmpty || !open) return;
    final r = _current = _queue.removeAt(0);
    r.timer = Timer(r.timeout, () => _finish(r, true));
    _write(r.bytes).catchError((_) => _finish(r, true));
  }

  void _finish(_Request r, bool timedOut) {
    if (!identical(_current, r)) return;
    r.timer?.cancel();
    r.idleTimer?.cancel();
    _current = null;
    if (!r.completer.isCompleted) r.completer.complete(Reply(r.lines, r.state, timedOut));
    _pump();
  }

  void _failPending() {
    final all = [?_current, ..._queue];
    _current = null;
    _queue.clear();
    for (final r in all) {
      r.timer?.cancel();
      r.idleTimer?.cancel();
      if (!r.completer.isCompleted) r.completer.complete(Reply(r.lines, r.state, true));
    }
  }

  void _onLine(String line) {
    if (_ignoreText) return;
    final r = _current;
    if (r != null) {
      final res = r.collect(line, r.state);
      if (res != Take.no) {
        r.lines.add(line);
        if (res == Take.done) {
          _finish(r, false);
        } else if (r.idle > Duration.zero) {
          r.idleTimer?.cancel();
          r.idleTimer = Timer(r.idle, () => _finish(r, false));
        }
        return;
      }
    }
    final q = parseQErr(line);
    if (q != null) {
      _qerrController.add(q);
      return;
    }
    if (line == 'Stcs' || line.isEmpty) return;
    _textController.add(line);
  }

  void _onMessage(int src, int id, Int32List values, int count) {
    _lastMessageMs = _now;
    onStream?.call(src, id, values, count);
  }

  // commands ---------------------------------------------------------------------------------------

  Future<VersionInfo?> getVersion() async {
    streaming = false; // 'V' also stops the stream and empties the board's output queue
    final r = await request(
      Cmd.version(),
      (l, s) => parseQErr(l) == null && l != 'Stcs' ? Take.more : Take.no,
      timeout: const Duration(milliseconds: 800),
      idle: const Duration(milliseconds: 120),
    );
    if (r.lines.isEmpty) return null;
    return parseVersion(r.lines.first)..extra = r.lines.sublist(1);
  }

  Future<LoadReading?> getLoad() async {
    final r = await request(Cmd.load(), (l, s) {
      final v = parseLoad(l);
      if (v == null) return Take.no;
      s['load'] = v;
      return Take.done;
    }, timeout: const Duration(milliseconds: 500));
    return r.state['load'] as LoadReading?;
  }

  Future<List<VoiceEntry>> listVoices() async {
    final r = await request(
      Cmd.voices(),
      (l, s) {
        final v = parseVoiceLine(l);
        if (v == null) return Take.no;
        ((s['voices'] ??= <VoiceEntry>[]) as List<VoiceEntry>).add(v);
        return Take.more;
      },
      timeout: const Duration(milliseconds: 700),
      idle: const Duration(milliseconds: 90),
    );
    return (r.state['voices'] as List<VoiceEntry>?) ?? const [];
  }

  Future<({bool ok, int index, String? name})?> selectVoice(int n) async {
    dropPending(Target.voice); // queued writes would land on the new voice's parameters
    final r = await request(selectVoiceCommand(n), (l, s) {
      final v = parseVoiceSelect(l);
      if (v == null) return Take.no;
      s['sel'] = v;
      return Take.done;
    });
    return r.state['sel'] as ({bool ok, int index, String? name})?;
  }

  Future<ParamList?> getParams(int target) async {
    final r = await request(Cmd.params(target), (l, s) {
      if (s['header'] == null) {
        final h = parseParamsHeader(l);
        if (h == null || h.target != target) return Take.no;
        s['header'] = h;
        s['params'] = <Param>[];
        return h.count == 0 ? Take.done : Take.more;
      }
      final p = parseParamLine(l);
      if (p == null) return Take.no;
      final list = s['params'] as List<Param>;
      list.add(p);
      final h = s['header'] as ({int target, String name, int count});
      return list.length >= h.count ? Take.done : Take.more;
    }, timeout: const Duration(milliseconds: 1500));
    final h = r.state['header'] as ({int target, String name, int count})?;
    if (h == null) return null;
    return ParamList(target, h.name, h.count, r.state['params'] as List<Param>, !r.timedOut);
  }

  /// The tuning and the pitch of every key (StcN). Null when the firmware does not answer.
  Future<TuningInfo?> getTuning() async {
    final r = await request(
      Cmd.tuning(),
      (l, s) {
        if (tuningHeaderLine.hasMatch(l)) {
          s['header'] = true;
          return Take.more;
        }
        if (s['header'] == true && tuningKeyLine.hasMatch(l)) {
          final n = ((s['keys'] ??= 0) as int) + 1;
          s['keys'] = n;
          return n >= 61 ? Take.done : Take.more;
        }
        return Take.no;
      },
      timeout: const Duration(milliseconds: 700),
      idle: const Duration(milliseconds: 90),
    );
    return parseTuningReply(r.lines);
  }

  /// Press a settings key on the board (StcK). Null when the firmware does not answer in time.
  Future<({bool ok, int id})?> pressSettingsKey(int id, {Duration timeout = const Duration(milliseconds: 300)}) async {
    final r = await request(settingsKeyCommand(id), (l, s) {
      final k = parseSettingsKeyReply(l);
      if (k == null) return Take.no;
      s['k'] = k;
      return Take.done;
    }, timeout: timeout);
    return r.state['k'] as ({bool ok, int id})?;
  }

  /// The settings-key layout (StcX): what every key does with Settings held. Null when the
  /// firmware does not answer (then it needs an update).
  Future<SettingsLayout?> getSettingsLayout() async {
    final r = await request(
      commandChar('X'),
      (l, s) {
        final t = l.trim();
        if (!t.startsWith('X ')) return Take.no;
        return t == 'X end' ? Take.done : Take.more;
      },
      timeout: const Duration(milliseconds: 1200),
    );
    return parseSettingsLayout(r.lines);
  }

  /// The board's state in one line (StcY); null without a reply.
  Future<BoardState?> getState({Duration timeout = const Duration(milliseconds: 500)}) async {
    final r = await request(commandChar('Y'), (l, s) {
      final b = parseBoardState(l);
      if (b == null) return Take.no;
      s['y'] = b;
      return Take.done;
    }, timeout: timeout);
    return r.state['y'] as BoardState?;
  }

  /// The current voice's hero knobs (StcH); null without a reply.
  Future<HeroKnobs?> getHeroes({Duration timeout = const Duration(milliseconds: 500)}) async {
    final r = await request(commandChar('H'), (l, s) {
      final h = parseHeroes(l);
      if (h == null) return Take.no;
      s['h'] = h;
      return Take.done;
    }, timeout: timeout);
    return r.state['h'] as HeroKnobs?;
  }

  /// The state's change counter (Stcy): it goes up whenever anything the board reports changed.
  Future<int?> getChangeCount({Duration timeout = const Duration(milliseconds: 400)}) async {
    final r = await request(commandChar('y'), (l, s) {
      final n = parseChangeCount(l);
      if (n == null) return Take.no;
      s['n'] = n;
      return Take.done;
    }, timeout: timeout);
    return r.state['n'] as int?;
  }

  /// The board's USB audio counters since the last call (StcU); they reset on every call. Null when
  /// the firmware does not answer (no USB audio) or the reply has none of its lines.
  Future<UsbAudioStats?> getUsbAudioStats() async {
    final r = await request(
      Cmd.usbAudio(),
      (l, s) {
        if (!usbAudioLine.hasMatch(l.trim())) return Take.no;
        return isLastUsbAudioLine(l) ? Take.done : Take.more;
      },
      timeout: const Duration(milliseconds: 500),
      idle: const Duration(milliseconds: 120),
    );
    return parseUsbAudioStats(r.lines);
  }

  /// Sets the board's USB audio ring target (frames, 49..256; 0 only asks). Returns the target the
  /// board reports, or null when the firmware does not answer (no Stct).
  Future<int?> setUsbAudioTarget(int frames) async {
    final r = await request(Cmd.usbAudioTarget(frames), (l, s) {
      final v = parseUsbAudioTarget(l);
      if (v == null) return Take.no;
      s['t'] = v;
      return Take.done;
    }, timeout: const Duration(milliseconds: 400));
    return r.state['t'] as int?;
  }

  /// A console command for the console drawer; replies are collected until quiet.
  Future<List<String>> raw(int byte) async {
    final r = await request(
      command(byte),
      (l, s) => parseQErr(l) == null ? Take.more : Take.no,
      timeout: const Duration(milliseconds: 1500),
      idle: const Duration(milliseconds: 150),
    );
    return r.lines;
  }

  Future<void> startStream() {
    streaming = true;
    _streamSentMs = _now;
    _watchdog ??= Timer.periodic(const Duration(seconds: 1), (_) => _checkStream());
    return _write(Cmd.streamOn());
  }

  Future<void> stopStream() {
    streaming = false;
    return _write(Cmd.streamOff());
  }

  /// Raw bytes, e.g. the bootloader command before a save.
  Future<void> send(Uint8List bytes) => _write(bytes);

  // The board streams motion ~60 times a second: a silent stream while other bytes arrive means it
  // got switched off, so ask for it again.
  void _checkStream() {
    if (!open) {
      _watchdog?.cancel();
      return;
    }
    final t = _now;
    final quiet = t - (_lastMessageMs > _streamSentMs ? _lastMessageMs : _streamSentMs);
    if (streaming && quiet > _streamSilenceMs && _lastBytesMs >= 0 && t - _lastBytesMs < _streamSilenceMs) {
      restarts++;
      _streamSentMs = t;
      _write(Cmd.streamOn()).catchError((_) {});
      _restreamController.add(quiet);
    }
  }

  ClientDiagnostics diagnostics() => ClientDiagnostics(
    parser.stats,
    rxBytes,
    streaming,
    restarts,
    _lastMessageMs < 0 ? null : Duration(milliseconds: _now - _lastMessageMs),
    _queue.length + (_current != null ? 1 : 0),
  );

  // parameters: the latest value per parameter goes out at most every 16 ms --------------------------

  void setParam(int target, int index, double value) {
    if (!open) return;
    _dirty[target * 256 + index] = ParamWrite(target, index, value);
    _scheduleFlush(0);
  }

  void dropPending(int target) => _dirty.removeWhere((_, p) => p.target == target);

  void _scheduleFlush(int ms) {
    if (_flushTimer != null && _flushTimer!.isActive) return;
    _flushTimer = Timer(Duration(milliseconds: ms), _flush);
  }

  void _flush() {
    if (!open || _dirty.isEmpty) return;
    if (_inFlight > 6) {
      _scheduleFlush(4);
      return;
    }
    final t = _now;
    final batch = <ParamWrite>[];
    var wait = 1 << 30;
    for (final k in _dirty.keys.toList()) {
      final since = t - (_lastSent[k] ?? -1000000);
      if (since >= _paramIntervalMs) {
        batch.add(_dirty.remove(k)!);
        _lastSent[k] = t;
      } else if (_paramIntervalMs - since < wait) {
        wait = _paramIntervalMs - since;
      }
    }
    for (final bytes in packSetParams(batch)) {
      _write(bytes).catchError((_) {});
    }
    sentParams += batch.length;
    if (_dirty.isNotEmpty) _scheduleFlush(wait < 1 ? 1 : wait);
  }
}
