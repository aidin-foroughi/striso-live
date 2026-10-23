// A scriptable AudioBackend for tests: devices come and go, configure applies at once (or when
// told), the input can be lost, macOS permission can be pending or denied. No audio, no files.

import 'backend.dart';

class FakeAudioBackend implements AudioBackend {
  List<AudioDevice> inputs, outputs;
  bool initOk = true, inited = false, shutdownCalled = false;

  /// The input exists but will not open (busy, exclusive elsewhere).
  bool failOpen = false;

  /// The output will not open.
  bool failOutput = false;

  /// configure() is applied on the next [apply] instead of at once.
  bool manualApply = false;

  /// macOS: Mic.* (Mic.na elsewhere).
  int mic = Mic.na;
  bool micRequested = false;

  final configs = <AudioConfig>[];
  final recordPaths = <String>[];
  int enumerations = 0, recordStops = 0;
  double gain = 0;
  String? documents;

  AudioStatus _st = const AudioStatus();
  AudioConfig _pending = AudioConfig.off;
  int _gen = 0;
  List<AudioDevice> _listedIn = const [], _listedOut = const [];

  FakeAudioBackend({List<AudioDevice>? inputs, List<AudioDevice>? outputs})
    : inputs = inputs ?? [const AudioDevice('Microphone (USB Audio)'), striso],
      outputs = outputs ?? [const AudioDevice('Speakers (Realtek)', isDefault: true), const AudioDevice('Headphones (USB)')];

  static const striso = AudioDevice('Striso Synth (Striso Synth)', isStriso: true, nativeBits: 24, nativeRate: 48000, nativeChannels: 2);

  AudioConfig get last => configs.isEmpty ? AudioConfig.off : configs.last;

  @override
  String get description => 'fake audio';

  @override
  bool init() {
    inited = initOk;
    if (inited) _st = _copy(initialised: true, micPermission: mic);
    return inited;
  }

  @override
  void shutdown() {
    shutdownCalled = true;
    inited = false;
  }

  @override
  void requestDevices() {
    enumerations++;
    _listedIn = List.of(inputs);
    _listedOut = List.of(outputs);
    _st = _copy(devicesGen: _st.devicesGen + 1);
  }

  @override
  List<AudioDevice> devices({required bool capture}) => capture ? _listedIn : _listedOut;

  @override
  int configure(AudioConfig c) {
    configs.add(c);
    _gen++;
    _pending = c;
    if (!manualApply) apply();
    return _gen;
  }

  /// Applies the last configure (with manualApply).
  void apply() {
    final c = _pending;
    var cap = DevState.closed, play = DevState.closed;
    var ce = AudioErr.ok, pe = AudioErr.ok;
    if (c.run) {
      final there = inputs.any((d) => d.name == c.input);
      if (!there) {
        cap = DevState.failed;
        ce = AudioErr.notFound;
      } else if (mic == Mic.undetermined || mic == Mic.denied || mic == Mic.restricted) {
        if (mic == Mic.undetermined) micRequested = true;
        cap = DevState.failed;
        ce = AudioErr.permission;
      } else if (failOpen) {
        cap = DevState.failed;
        ce = AudioErr.openCapture;
      } else {
        cap = DevState.running;
      }
      if (cap == DevState.running && c.monitor) {
        final outThere = c.output.isEmpty || outputs.any((d) => d.name == c.output);
        if (failOutput || !outThere) {
          play = DevState.failed;
          pe = outThere ? AudioErr.openPlayback : AudioErr.notFound;
        } else {
          play = DevState.running;
        }
      }
    }
    final keepRec = cap == DevState.running && _st.capture == DevState.running && _st.record == RecState.on;
    _st = _copy(
      configGen: _gen,
      capture: cap,
      captureError: ce,
      captureRate: cap == DevState.running ? 48000 : 0,
      capturePeriod: cap == DevState.running ? c.period : 0,
      captureBits: cap == DevState.running ? (c.exclusive ? 24 : -32) : 0,
      captureExclusive: cap == DevState.running && c.exclusive,
      playback: play,
      playbackExclusive: play == DevState.running && c.exclusiveOutput,
      playbackError: pe,
      playbackRate: play == DevState.running ? 48000 : 0,
      latencyMs: play == DevState.running ? 7.5 : 0,
      streaming: play == DevState.running,
      record: keepRec ? RecState.on : (_st.record == RecState.on ? RecState.stopped : _st.record),
      recordError: keepRec ? AudioErr.ok : (_st.record == RecState.on ? AudioErr.ok : _st.recordError),
    );
  }

  /// The board went away: the input stops by itself (and is no longer listed).
  void unplug() {
    inputs = inputs.where((d) => d.name != striso.name).toList();
    lose();
  }

  void plug() {
    if (!inputs.any((d) => d.name == striso.name)) inputs = [...inputs, striso];
  }

  /// The running input stops by itself (a recording ends with it).
  void lose() {
    if (_st.capture != DevState.running) return;
    final rec = _st.record == RecState.on;
    _st = _copy(
      capture: DevState.lost,
      captureError: AudioErr.lost,
      playback: DevState.closed,
      streaming: false,
      record: rec ? RecState.stopped : _st.record,
      recordError: rec ? AudioErr.lost : _st.recordError,
    );
  }

  /// The output stops by itself.
  void loseOutput() => _st = _copy(playback: DevState.lost, playbackError: AudioErr.lost, streaming: false);

  /// Input frames pass (levels, recording length).
  void run(int frames, {double level = 0.25}) {
    if (_st.capture != DevState.running) return;
    _st = _copy(
      levelL: level,
      levelR: level,
      captureCallbacks: _st.captureCallbacks + frames ~/ 128,
      recordFrames: _st.record == RecState.on ? _st.recordFrames + frames : _st.recordFrames,
    );
  }

  void setMic(int m) {
    mic = m;
    _st = _copy(micPermission: m);
  }

  @override
  void setGain(double linear) {
    gain = linear;
    _st = _copy(gain: linear);
  }

  @override
  void recordStart(String path) {
    recordPaths.add(path);
    if (_st.capture != DevState.running) {
      _st = _copy(record: RecState.stopped, recordError: AudioErr.notRunning);
      return;
    }
    _st = _copy(record: RecState.on, recordError: AudioErr.ok, recordFrames: 0, recordBits: _st.captureBits == 24 ? 24 : -32);
  }

  @override
  void recordStop() {
    recordStops++;
    if (_st.record == RecState.on) _st = _copy(record: RecState.idle);
  }

  @override
  AudioStatus status() => _st;

  @override
  String? documentsDir() => documents;

  @override
  void requestMic() => micRequested = true;

  AudioStatus _copy({
    bool? initialised,
    int? configGen,
    int? devicesGen,
    DevState? capture,
    int? captureError,
    int? captureRate,
    int? capturePeriod,
    int? captureBits,
    int? captureCallbacks,
    bool? captureExclusive,
    DevState? playback,
    bool? playbackExclusive,
    int? playbackError,
    int? playbackRate,
    double? levelL,
    double? levelR,
    double? gain,
    double? latencyMs,
    bool? streaming,
    RecState? record,
    int? recordError,
    int? recordBits,
    int? recordFrames,
    int? micPermission,
  }) {
    final s = _st;
    return AudioStatus(
      initialised: initialised ?? s.initialised,
      configGen: configGen ?? s.configGen,
      devicesGen: devicesGen ?? s.devicesGen,
      capture: capture ?? s.capture,
      captureError: captureError ?? s.captureError,
      captureRate: captureRate ?? s.captureRate,
      captureChannels: 2,
      capturePeriod: capturePeriod ?? s.capturePeriod,
      captureBits: captureBits ?? s.captureBits,
      captureCallbacks: captureCallbacks ?? s.captureCallbacks,
      captureExclusive: captureExclusive ?? s.captureExclusive,
      playback: playback ?? s.playback,
      playbackExclusive: playbackExclusive ?? s.playbackExclusive,
      playbackError: playbackError ?? s.playbackError,
      playbackRate: playbackRate ?? s.playbackRate,
      playbackPeriod: s.playbackPeriod,
      playbackPeriods: s.playbackPeriods,
      levelL: levelL ?? s.levelL,
      levelR: levelR ?? s.levelR,
      gain: gain ?? s.gain,
      latencyMs: latencyMs ?? s.latencyMs,
      streaming: streaming ?? s.streaming,
      record: record ?? s.record,
      recordError: recordError ?? s.recordError,
      recordBits: recordBits ?? s.recordBits,
      recordFrames: recordFrames ?? s.recordFrames,
      micPermission: micPermission ?? s.micPermission,
    );
  }
}
