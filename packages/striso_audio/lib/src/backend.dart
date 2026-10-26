// What the "Through PC" engine needs from the native audio library, as plain Dart: device lists,
// the wanted state, the status. NativeAudioBackend (native.dart) is striso_audio through
// dart:ffi; FakeAudioBackend (fake.dart) is a scriptable one for tests. Every call returns at
// once: the native side opens and closes devices on its own thread.

/// How a device is connected (SA_TRANSPORT_*).
enum AudioTransport {
  unknown,
  usb,
  bluetooth,
  builtin,
  hdmi,
  virtual,
  thunderbolt,
  pci;

  static AudioTransport of(int v) => v >= 0 && v < values.length ? values[v] : unknown;
}

/// One input or output device.
class AudioDevice {
  final String name;

  /// Stable across reboots and renames: the WASAPI endpoint id (Windows), the device UID (macOS);
  /// the name where the system has none.
  final String id;
  final AudioTransport transport;

  /// Windows: the device's minimum and default period in frames (0: unknown).
  final int devMin, devDefault;
  final bool isDefault;

  /// Identified as the Striso by its USB VID/PID (where the system tells).
  final bool isStriso;

  /// 16, 24, 32 (integer), -32 (float) or 0 (unknown); inputs only.
  final int nativeBits;
  final int nativeRate, nativeChannels;

  const AudioDevice(
    this.name, {
    String? id,
    this.transport = AudioTransport.unknown,
    this.devMin = 0,
    this.devDefault = 0,
    this.isDefault = false,
    this.isStriso = false,
    this.nativeBits = 0,
    this.nativeRate = 0,
    this.nativeChannels = 0,
  }) : id = id ?? name;

  /// Bluetooth adds 150-250 ms: by the system's word, or by the name where it says nothing.
  bool get isBluetooth =>
      transport == AudioTransport.bluetooth ||
      (transport == AudioTransport.unknown && RegExp(r'bluetooth|airpods|\bbt\b|hands-free|a2dp', caseSensitive: false).hasMatch(name)) ||
      RegExp(r'BTHENUM|BTHLEDevice|BTHLE[#\\]', caseSensitive: false).hasMatch(id);

  @override
  String toString() => 'AudioDevice($name${isDefault ? ', default' : ''}${isStriso ? ', Striso' : ''})';
}

/// The wanted state of the native side (sa_configure).
class AudioConfig {
  final bool run;

  /// Exact input name ('' would mean: the native side looks for the Striso itself).
  final String input;

  /// Exact output name, '' for the system default.
  final String output;
  final int period;

  /// Play the input to the output (Through PC); false: input only (meters, recording).
  final bool monitor;

  /// Windows: try the input in exclusive mode first.
  final bool exclusive;

  /// Windows: try the output in exclusive mode first (other programs cannot play to it meanwhile).
  final bool exclusiveOutput;

  /// The output alone, no input: it plays silence (measurements of the output; native API 3).
  final bool outputOnly;

  const AudioConfig({
    required this.run,
    this.input = '',
    this.output = '',
    this.period = 128,
    this.monitor = false,
    this.exclusive = true,
    this.exclusiveOutput = false,
    this.outputOnly = false,
  });

  static const off = AudioConfig(run: false);

  @override
  bool operator ==(Object other) =>
      other is AudioConfig &&
      other.run == run &&
      other.input == input &&
      other.output == output &&
      other.period == period &&
      other.monitor == monitor &&
      other.exclusive == exclusive &&
      other.exclusiveOutput == exclusiveOutput &&
      other.outputOnly == outputOnly;

  @override
  int get hashCode => Object.hash(run, input, output, period, monitor, exclusive, exclusiveOutput, outputOnly);

  @override
  String toString() =>
      'AudioConfig(${run ? 'run' : 'off'}, in "$input", out "${output.isEmpty ? 'default' : output}", $period, ${monitor ? 'monitor' : 'input only'}${exclusive ? ', exclusive input' : ''}${exclusiveOutput ? ', exclusive output' : ''}${outputOnly ? ', output only' : ''})';
}

/// Device states (SA_DEV_*).
enum DevState { closed, running, lost, failed }

/// Recording states (SA_REC_*).
enum RecState { idle, on, stopped }

/// Error codes (SA_ERR_*).
class AudioErr {
  static const ok = 0,
      noContext = -1,
      notFound = -2,
      openCapture = -3,
      openPlayback = -4,
      permission = -5,
      lost = -6,
      file = -7,
      fileFull = -8,
      notRunning = -9,
      badArg = -10,
      notInitialised = -11;

  static String text(int e) => switch (e) {
    ok => 'ok',
    noContext => 'the audio system did not start',
    notFound => 'not found',
    openCapture => 'the input would not open',
    openPlayback => 'the output would not open',
    permission => 'audio input is not allowed',
    lost => 'the device went away',
    file => 'the file could not be written',
    fileFull => 'the file reached its 4 GB limit',
    notRunning => 'the input is not running',
    badArg => 'bad argument',
    notInitialised => 'not initialised',
    _ => 'error $e',
  };
}

/// macOS audio input permission (SA_MIC_*).
class Mic {
  static const na = -1, undetermined = 0, restricted = 1, denied = 2, authorized = 3;
}

/// A snapshot of sa_status.
class AudioStatus {
  final bool initialised;
  final int configGen, devicesGen;
  final DevState capture;
  final int captureError, captureResult, captureRate, captureChannels, capturePeriod, captureBits, captureCallbacks;
  final bool captureExclusive;
  final DevState playback;
  final bool playbackExclusive;
  final int playbackError, playbackResult, playbackRate, playbackPeriod, playbackPeriods, playbackCallbacks;
  final double levelL, levelR, levelOut, gain;
  final double latencyMs, ringMs, targetMs, driftPpm;
  final int underruns, overruns, resyncs;
  final bool streaming;
  final RecState record;
  final int recordError, recordBits, recordFrames, recordDropped;
  final int micPermission;

  // API 2: device-reported buffers and latencies, the breakdown, dropouts by cause, timing
  final int captureBuffer, captureDevMin, captureDevDefault, captureStreamLatency, captureExclResult;
  final int playbackBuffer, playbackDevMin, playbackDevDefault, playbackStreamLatency, playbackExclResult;
  final AudioTransport playbackTransport;
  final double inMs, outMs, marginMs;
  final int inLate, outLate, outGlitches, servoLimits, retargets, eventsLost;
  final int capNominalUs, capMaxGapUs, capRecentGapUs, capBurst, capBurstMax;
  final int playNominalUs, playMaxGapUs, playRecentGapUs, playBurst, playBurstMax;

  /// The library's clock (us since it started): the events' times are on it.
  final int nowUs;
  final int eventSeq;

  /// RtFlags of the device threads and the control thread.
  final int rtCapture, rtPlayback, rtControl;
  final bool timer1ms, powerThrottlingOff;

  // API 3: measurements (NativeAudioBackend.probe)
  /// Input buffers the system flagged as discontinuous (WASAPI): input-side glitches.
  final int capDiscontinuities;

  /// Silence guard on: output samples that were not 0 (each was forced to 0).
  final int silenceViolations;
  final int probeLost;
  final bool probeOn, silenceGuard;

  /// While probing: CPU time of the device threads, and the time inside this library's callbacks (us, wrap at 2^32).
  final int cpuCaptureUs, cpuPlaybackUs, busyCaptureUs, busyPlaybackUs;

  /// The output reports where it plays (Windows IAudioClock; Core Audio presentation times).
  final bool playbackClock;

  /// The output volume the library applies: an exclusive output's system volume (Windows applies
  /// it to a shared output only), 0 muted; 1 otherwise.
  final double playbackVolume;

  const AudioStatus({
    this.initialised = false,
    this.configGen = 0,
    this.devicesGen = 0,
    this.capture = DevState.closed,
    this.captureError = 0,
    this.captureResult = 0,
    this.captureRate = 0,
    this.captureChannels = 0,
    this.capturePeriod = 0,
    this.captureBits = 0,
    this.captureCallbacks = 0,
    this.captureExclusive = false,
    this.playback = DevState.closed,
    this.playbackExclusive = false,
    this.playbackError = 0,
    this.playbackResult = 0,
    this.playbackRate = 0,
    this.playbackPeriod = 0,
    this.playbackPeriods = 0,
    this.playbackCallbacks = 0,
    this.levelL = 0,
    this.levelR = 0,
    this.levelOut = 0,
    this.gain = 0,
    this.latencyMs = 0,
    this.ringMs = 0,
    this.targetMs = 0,
    this.driftPpm = 0,
    this.underruns = 0,
    this.overruns = 0,
    this.resyncs = 0,
    this.streaming = false,
    this.record = RecState.idle,
    this.recordError = 0,
    this.recordBits = 0,
    this.recordFrames = 0,
    this.recordDropped = 0,
    this.micPermission = Mic.na,
    this.captureBuffer = 0,
    this.captureDevMin = 0,
    this.captureDevDefault = 0,
    this.captureStreamLatency = 0,
    this.captureExclResult = 0,
    this.playbackBuffer = 0,
    this.playbackDevMin = 0,
    this.playbackDevDefault = 0,
    this.playbackStreamLatency = 0,
    this.playbackExclResult = 0,
    this.playbackTransport = AudioTransport.unknown,
    this.inMs = 0,
    this.outMs = 0,
    this.marginMs = 0,
    this.inLate = 0,
    this.outLate = 0,
    this.outGlitches = 0,
    this.servoLimits = 0,
    this.retargets = 0,
    this.eventsLost = 0,
    this.capNominalUs = 0,
    this.capMaxGapUs = 0,
    this.capRecentGapUs = 0,
    this.capBurst = 0,
    this.capBurstMax = 0,
    this.playNominalUs = 0,
    this.playMaxGapUs = 0,
    this.playRecentGapUs = 0,
    this.playBurst = 0,
    this.playBurstMax = 0,
    this.nowUs = 0,
    this.eventSeq = 0,
    this.rtCapture = 0,
    this.rtPlayback = 0,
    this.rtControl = 0,
    this.timer1ms = false,
    this.powerThrottlingOff = false,
    this.capDiscontinuities = 0,
    this.silenceViolations = 0,
    this.probeLost = 0,
    this.probeOn = false,
    this.silenceGuard = false,
    this.cpuCaptureUs = 0,
    this.cpuPlaybackUs = 0,
    this.busyCaptureUs = 0,
    this.busyPlaybackUs = 0,
    this.playbackClock = false,
    this.playbackVolume = 1,
  });

  static const idle = AudioStatus();

  /// Dropouts the listener hears: the ring empty, the output device late beyond its buffer, input
  /// dropped on a full ring, cut-backs after a stall.
  int get dropouts => underruns + outGlitches + overruns + resyncs;
}

/// sa_status.rt_* flags.
class RtFlags {
  static const mmcss = 1, critical = 2, timeCritical = 4, hal = 8;

  static String text(int f) {
    if (f == 0) return 'normal priority';
    return [
      if (f & hal != 0) 'Core Audio real-time IO thread',
      if (f & mmcss != 0) 'MMCSS Pro Audio${f & critical != 0 ? ' (critical)' : ''}',
      if (f & timeCritical != 0) 'time critical',
    ].join(', ');
  }
}

/// SA_EV_*
class Ev {
  static const inLate = 1, inOverrun = 2, ringEmpty = 3, outLate = 4, resync = 5, servoLimit = 6, target = 7, stream = 8, open = 9, rt = 10;
}

/// One entry of the native event log, with its cause.
class AudioEvent {
  final int seq, type;

  /// Microseconds on the library's clock (AudioStatus.nowUs).
  final int tUs;
  final int a, b, c;
  const AudioEvent(this.seq, this.type, this.tUs, this.a, this.b, this.c);

  /// What the listener hears as a dropout.
  bool get isDropout => type == Ev.ringEmpty || type == Ev.inOverrun || type == Ev.resync || (type == Ev.outLate && c != 0);

  /// Which side caused a dropout: the input (late, or dropped on a full ring) or the output (late,
  /// or took more than the ring held).
  bool get inputSide => type == Ev.inOverrun || (type == Ev.ringEmpty && c != 0);

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);

  /// For the log: "dropout: ring empty (input late, its last block 4.2 ms ago)".
  String get text => switch (type) {
    Ev.inLate => 'input late: ${_ms(a)} ms between blocks (typical ${_ms(b)} ms), $c frames left in the ring',
    Ev.inOverrun => 'dropout: ring full, $a input frames dropped',
    Ev.ringEmpty =>
      c != 0
          ? 'dropout: ring empty (input late, its last block ${_ms(b)} ms ago), $a frames short'
          : 'dropout: ring empty (output took more than the ring held, the input on time), $a frames short',
    Ev.outLate =>
      c != 0
          ? 'dropout: output late, ${_ms(a)} ms between wake-ups (typical ${_ms(b)} ms): more than the device buffer bridges'
          : 'output late: ${_ms(a)} ms between wake-ups (typical ${_ms(b)} ms), within the device buffer',
    Ev.resync => 'dropout: the ring was too full after a stall, $a frames cut',
    Ev.servoLimit => 'drift servo at its limit (${a > 0 ? '+' : ''}$a ppm; the ring ${b.abs()} frames ${b >= 0 ? 'over' : 'under'} its target)',
    Ev.target => 'ring target ${c != 0 ? 'tighter' : 'looser'}: $b -> $a frames',
    Ev.stream => 'playing: ring target $a frames',
    Ev.open => '${a != 0 ? 'input' : 'output'} open: $b frames per wake-up${c != 0 ? ', exclusive' : ', shared'}',
    Ev.rt => '${a != 0 ? 'input' : 'output'} thread: ${RtFlags.text(b)}',
    _ => 'event $type ($a, $b, $c)',
  };
}

abstract class AudioBackend {
  /// "striso_audio 1, miniaudio 0.11.25" (for the log).
  String get description;

  /// Starts the native side (no device is opened). False when the audio system did not start.
  bool init();
  void shutdown();

  /// Asks for a fresh device list; status().devicesGen goes up when it is there.
  void requestDevices();
  List<AudioDevice> devices({required bool capture});

  /// Returns the generation status().configGen reaches once applied.
  int configure(AudioConfig c);
  void setGain(double linear);
  void recordStart(String path);
  void recordStop();
  AudioStatus status();

  /// The native event log after [afterSeq], oldest first.
  List<AudioEvent> events(int afterSeq);

  /// The user's Documents folder, or null.
  String? documentsDir();

  /// macOS: the audio input permission prompt.
  void requestMic();

  /// The output's own source for the output alone (sa_set_source): an sa_source_fn and its user
  /// pointer as addresses, 0 and 0 to detach. Returns 0 once the output callback is no longer in
  /// the previous source, < 0 when it could not be set (no such function in this build, or the
  /// callback did not leave it in time).
  int setSource(int fn, int user);
}
