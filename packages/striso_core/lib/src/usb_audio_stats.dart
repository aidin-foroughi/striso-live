// The board's USB audio counters (console StcU, firmware with USB audio): packets sent and missed,
// the 47/48/49 sizes, its ring before each packet, underruns/overruns/primes since the last call.
// The reply is text for people; the parser takes each number by its words, so lines may move,
// gain words or go missing (a field the firmware does not print stays null).
//
// usb audio: streaming 48000 Hz 24 bit (alt 1), source synth
// since last U: packets sent 2000 missed 0 built 2000 (47:3 48:1994 49:3)
// rate: 96000 frames in 2000 ms of host clock = 48000.000 Hz
// ring: level 150 now, 146 filtered, 98..190 before packets (target 144 of 512)
// underruns 0 overruns 0 primes 0; packet build avg 900 max 1400 cycles

class UsbAudioStats {
  final bool? streaming;
  final int? alt, sent, missed, built, size47, size48, size49;
  final double? rateHz;
  final int? ringNow, ringFiltered, ringMin, ringMax, ringTarget, ringSize;
  final bool priming;
  final int? underruns, overruns, primes;
  final List<String> lines;

  const UsbAudioStats({
    this.streaming,
    this.alt,
    this.sent,
    this.missed,
    this.built,
    this.size47,
    this.size48,
    this.size49,
    this.rateHz,
    this.ringNow,
    this.ringFiltered,
    this.ringMin,
    this.ringMax,
    this.ringTarget,
    this.ringSize,
    this.priming = false,
    this.underruns,
    this.overruns,
    this.primes,
    this.lines = const [],
  });

  /// The board's own dropouts since the last poll.
  int get drops => (underruns ?? 0) + (overruns ?? 0);

  @override
  String toString() =>
      'UsbAudioStats(${streaming == true ? 'streaming' : 'idle'}, sent $sent missed $missed, 47/48/49 $size47/$size48/$size49, '
      'ring $ringMin..$ringMax (filtered $ringFiltered, target $ringTarget), underruns $underruns overruns $overruns primes $primes)';
}

/// The lines of a StcU reply: they all carry one of these.
final usbAudioLine = RegExp(r'^(usb audio|since last u|rate:|ring:|underruns|.*\bprimes\b)', caseSensitive: false);

int? _int(String text, String pattern) {
  final m = RegExp(pattern, caseSensitive: false).firstMatch(text);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Null when nothing in [lines] looks like a StcU reply.
UsbAudioStats? parseUsbAudioStats(List<String> lines) {
  final mine = lines.where((l) => usbAudioLine.hasMatch(l.trim())).toList();
  if (mine.isEmpty) return null;
  final all = mine.join('\n');
  final head = mine.firstWhere((l) => l.toLowerCase().startsWith('usb audio'), orElse: () => '');
  final rm = RegExp(r'^ring:.*$', caseSensitive: false, multiLine: true).firstMatch(all)?.group(0) ?? '';
  final range = RegExp(r'(-?\d+)\s*\.\.\s*(-?\d+)').firstMatch(rm);
  final rate = RegExp(r'=\s*([\d.]+)\s*hz', caseSensitive: false).firstMatch(all);
  return UsbAudioStats(
    streaming: head.isEmpty ? null : head.toLowerCase().contains('streaming'),
    alt: _int(head, r'\balt\s+(\d+)'),
    sent: _int(all, r'\bsent\s+(\d+)'),
    missed: _int(all, r'\bmissed\s+(\d+)'),
    built: _int(all, r'\bbuilt\s+(\d+)'),
    size47: _int(all, r'\b47\s*:\s*(\d+)'),
    size48: _int(all, r'\b48\s*:\s*(\d+)'),
    size49: _int(all, r'\b49\s*:\s*(\d+)'),
    rateHz: rate == null ? null : double.tryParse(rate.group(1)!),
    ringNow: _int(rm, r'\blevel\s+(\d+)'),
    ringFiltered: _int(rm, r'(-?\d+)\s+filtered'),
    ringMin: range == null ? null : int.tryParse(range.group(1)!),
    ringMax: range == null ? null : int.tryParse(range.group(2)!),
    ringTarget: _int(rm, r'\btarget\s+(\d+)'),
    ringSize: _int(rm, r'\btarget\s+\d+\s+of\s+(\d+)'),
    priming: rm.toLowerCase().contains('priming'),
    underruns: _int(all, r'\bunderruns\s+(\d+)'),
    overruns: _int(all, r'\boverruns\s+(\d+)'),
    primes: _int(all, r'\bprimes\s+(\d+)'),
    lines: mine,
  );
}
