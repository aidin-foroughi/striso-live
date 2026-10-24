// What runs right now, by name: the console, the stream, the pollers, the audio engine's devices,
// the virtual board, MIDI inputs. Everything that holds a device or a timer registers here while it
// runs, so the status can say what is really open and a test can check that Disconnect left
// nothing behind.

class Resources {
  final _on = <String, String>{};
  final _listeners = <void Function()>[];

  /// [name] runs ([what] says how, for the log and the status tooltip).
  void up(String name, [String what = '']) {
    if (_on[name] == what) return;
    _on[name] = what;
    _notify();
  }

  void down(String name) {
    if (_on.remove(name) != null) _notify();
  }

  void set(String name, bool on, [String what = '']) => on ? up(name, what) : down(name);

  bool has(String name) => _on.containsKey(name);
  String? what(String name) => _on[name];
  Map<String, String> get active => Map.unmodifiable(_on);
  bool get isEmpty => _on.isEmpty;

  void addListener(void Function() f) => _listeners.add(f);
  void removeListener(void Function() f) => _listeners.remove(f);

  void _notify() {
    for (final f in List.of(_listeners)) {
      f();
    }
  }

  @override
  String toString() => _on.isEmpty ? 'nothing running' : _on.entries.map((e) => e.value.isEmpty ? e.key : '${e.key} (${e.value})').join(', ');
}

/// The names used.
class Res {
  static const console = 'console', stream = 'stream', presence = 'presence poll', reconnect = 'reconnect timer';
  static const statePoll = 'state poll', loadPoll = 'load poll', usbAudioPoll = 'USB audio poll', tuningPoll = 'tuning poll';
  static const audioInput = 'audio input', audioOutput = 'audio output', audioEngine = 'audio engine';
  static const virtualBoard = 'virtual board', midi = 'MIDI inputs';
}
