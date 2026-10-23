/// The Striso's USB audio input through the computer for Striso Live: play it through an output
/// device with low latency (drift-compensated duplex passthrough) and record it to WAV, on a
/// small native library (miniaudio) through dart:ffi. Dart only sets the wanted state and reads
/// the status; the audio stays on the native threads.
library;

export 'src/backend.dart';
export 'src/fake.dart';
export 'src/native.dart' show NativeAudioBackend, StrisoAudioLib, strisoAudioCandidates, backendSystem, backendNull;
export 'src/through_pc.dart';
