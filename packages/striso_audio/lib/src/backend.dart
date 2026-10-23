// What the "Through PC" engine needs from the native audio library, as plain Dart: device lists,
// the wanted state, the status. NativeAudioBackend (native.dart) is striso_audio through
// dart:ffi; FakeAudioBackend (fake.dart) is a scriptable one for tests. Every call returns at
// once: the native side opens and closes devices on its own thread.

/// One input or output device.
class AudioDevice {
  final String name;
  final bool isDefault;

  /// Identified as the Striso by its USB VID/PID (where the system tells).
  final bool isStriso;

  /// 16, 24, 32 (integer), -32 (float) or 0 (unknown); inputs only.
  final int nativeBits;
  final int nativeRate, nativeChannels;

  const AudioDevice(this.name, {this.isDefault = false, this.isStriso = false, this.nativeBits = 0, this.nativeRate = 0, this.nativeChannels = 0});

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

  const AudioConfig({
    required this.run,
    this.input = '',
    this.output = '',
    this.period = 128,
    this.monitor = false,
    this.exclusive = true,
    this.exclusiveOutput = false,
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
      other.exclusiveOutput == exclusiveOutput;

  @override
  int get hashCode => Object.hash(run, input, output, period, monitor, exclusive, exclusiveOutput);

  @override
  String toString() =>
      'AudioConfig(${run ? 'run' : 'off'}, in "$input", out "${output.isEmpty ? 'default' : output}", $period, ${monitor ? 'monitor' : 'input only'}${exclusive ? ', exclusive input' : ''}${exclusiveOutput ? ', exclusive output' : ''})';
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
  });

  static const idle = AudioStatus();

  /// Dropouts the listener hears: output underruns, input overruns and cut-backs.
  int get dropouts => underruns + overruns + resyncs;
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

  /// The user's Documents folder, or null.
  String? documentsDir();

  /// macOS: the audio input permission prompt.
  void requestMic();
}
