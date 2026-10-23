// The board's USB audio counters (console StcU, firmware with USB audio): packets sent and missed,
// the 47/48/49 sizes, its ring before each packet, underruns/overruns/primes since the last call,
// and in the UAC2 firmware also host-skipped frames, frames not ready at SOF, SOF timing, the
// host's fetch window, the synth's commit timing and lost blocks, the USB audio CPU share and the
// longest lock (doc/usb_audio.md in the firmware). The reply is text for people; the parser takes
// each number by its words, line by line, so lines may move, gain words or go missing (a field the
// firmware does not print stays null).
//
// UAC1 firmware:
//   usb audio: streaming 48000 Hz 24 bit (alt 1), source synth
//   since last U: packets sent 2000 missed 0 built 2000 (47:3 48:1994 49:3)
//   rate: 96000 frames in 2000 ms of host clock = 48000.000 Hz
//   ring: level 150 now, 146 filtered, 98..190 before packets (target 144 of 512)
//   underruns 0 overruns 0 primes 0; packet build avg 900 max 1400 cycles
// UAC2 firmware:
//   usb audio (UAC2): streaming 48000 Hz 24 bit (alt 1), source synth
//   since last U: packets sent 30012 missed 0 (host skipped 0, flushed early 0); built 30012 (47:31 48:29950 49:31)
//   rate: 1440560 frames in 30012 ms of host clock = 48000.266 Hz
//   ring: level 104 now, 96 filtered, 65..128 before packets (target 96 = 2000 us, of 512)
//   faults: underruns 0 overruns 0 primes 0 (silent packets 0), fast starts 1
//   frames: not ready at SOF 0; SOF late (>1.1 ms) 0 lost 0, max interval 1012 us
//   builds: after fetch 30012, after miss 0, at SOF 1; fetch at 95..140 us (avg 110) after SOF; build avg 1900 max 2600 cycles
//   synth: commit 210 us avg, 420 max after its DMA interrupt (block 667 us); off cadence 0; since boot: blocks lost 0, repeated 0
//   cpu: usb audio ISR hooks 9000000 cycles = 0.22% over 30012 ms; longest lock: thread 12 us, ISR 4 us

class UsbAudioStats {
  final bool? streaming;

  /// 1 or 2 (from "usb audio (UAC2)"); null for firmware that does not say.
  final int? uac;
  final int? alt, sent, missed, built, size47, size48, size49;

  /// UAC2 firmware: the host did not fetch a packet in its frame (a 1 ms gap), or the LLD flushed
  /// one due in the next frame (sent again, nothing lost).
  final int? hostSkipped, flushedEarly;
  final double? rateHz;
  final int? ringNow, ringFiltered, ringMin, ringMax, ringTarget, ringSize;
  final bool priming;
  final int? underruns, overruns, primes, silentPackets, fastStarts;

  /// UAC2 firmware: a packet was not in the FIFO at its frame's SOF; the USB interrupt held off.
  final int? notReady, sofLate, sofLost, sofMaxIntervalUs;

  /// The host's fetch window after SOF (us).
  final int? fetchMinUs, fetchMaxUs;
  final int? synthCommitMaxUs, offCadence, blocksLost;
  final double? cpuPercent;
  final int? lockThreadUs, lockIsrUs;
  final List<String> lines;

  const UsbAudioStats({
    this.streaming,
    this.uac,
    this.alt,
    this.sent,
    this.missed,
    this.built,
    this.size47,
    this.size48,
    this.size49,
    this.hostSkipped,
    this.flushedEarly,
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
    this.silentPackets,
    this.fastStarts,
    this.notReady,
    this.sofLate,
    this.sofLost,
    this.sofMaxIntervalUs,
    this.fetchMinUs,
    this.fetchMaxUs,
    this.synthCommitMaxUs,
    this.offCadence,
    this.blocksLost,
    this.cpuPercent,
    this.lockThreadUs,
    this.lockIsrUs,
    this.lines = const [],
  });

  /// The board's side of the dropouts since the last poll: its ring ran dry, the host skipped a
  /// frame, a packet was not ready at its frame.
  int get drops => (underruns ?? 0) + (hostSkipped ?? 0) + (notReady ?? 0);

  @override
  String toString() =>
      'UsbAudioStats(${streaming == true ? 'streaming' : 'idle'}${uac != null ? ' UAC$uac' : ''}, sent $sent missed $missed '
      '(host skipped $hostSkipped), 47/48/49 $size47/$size48/$size49, ring $ringMin..$ringMax (filtered $ringFiltered, '
      'target $ringTarget), underruns $underruns overruns $overruns not ready $notReady)';
}

/// The lines of a StcU reply: they all start with one of these words.
final usbAudioLine = RegExp(r'^(usb audio|since last u|rate:|ring:|underruns|faults:|frames:|builds:|synth:|cpu:)', caseSensitive: false);

/// The last line of a reply (UAC2 firmware; older firmware ends with the "underruns" line).
bool isLastUsbAudioLine(String l) {
  final t = l.trim().toLowerCase();
  return t.startsWith('cpu:') || t.startsWith('underruns');
}

int? _int(String text, String pattern) {
  final m = RegExp(pattern, caseSensitive: false).firstMatch(text);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// Null when nothing in [lines] looks like a StcU reply.
UsbAudioStats? parseUsbAudioStats(List<String> lines) {
  final mine = lines.map((l) => l.trim()).where(usbAudioLine.hasMatch).toList();
  if (mine.isEmpty) return null;
  String line(String start) => mine.firstWhere((l) => l.toLowerCase().startsWith(start), orElse: () => '');
  final head = line('usb audio');
  final pk = line('since last u');
  final rm = line('ring:');
  // underruns live on the "faults:" line (UAC2) or a line of their own (UAC1)
  final faults = [line('faults:'), line('underruns')].where((l) => l.isNotEmpty).join(' ');
  final fr = line('frames:');
  final bu = line('builds:');
  final sy = line('synth:');
  final cpu = line('cpu:');
  final range = RegExp(r'(-?\d+)\s*\.\.\s*(-?\d+)').firstMatch(rm);
  final fetch = RegExp(r'fetch at\s+(\d+)\s*\.\.\s*(\d+)', caseSensitive: false).firstMatch(bu);
  final rate = RegExp(r'=\s*([\d.]+)\s*hz', caseSensitive: false).firstMatch(line('rate:'));
  final pct = RegExp(r'=\s*([\d.]+)\s*%').firstMatch(cpu);
  return UsbAudioStats(
    streaming: head.isEmpty ? null : head.toLowerCase().contains('streaming'),
    uac: _int(head, r'\(uac\s*(\d)\)'),
    alt: _int(head, r'\balt\s+(\d+)'),
    sent: _int(pk, r'\bsent\s+(\d+)'),
    missed: _int(pk, r'\bmissed\s+(\d+)'),
    built: _int(pk, r'\bbuilt\s+(\d+)'),
    size47: _int(pk, r'\b47\s*:\s*(\d+)'),
    size48: _int(pk, r'\b48\s*:\s*(\d+)'),
    size49: _int(pk, r'\b49\s*:\s*(\d+)'),
    hostSkipped: _int(pk, r'host skipped\s+(\d+)'),
    flushedEarly: _int(pk, r'flushed early\s+(\d+)'),
    rateHz: rate == null ? null : double.tryParse(rate.group(1)!),
    ringNow: _int(rm, r'\blevel\s+(\d+)'),
    ringFiltered: _int(rm, r'(-?\d+)\s+filtered'),
    ringMin: range == null ? null : int.tryParse(range.group(1)!),
    ringMax: range == null ? null : int.tryParse(range.group(2)!),
    ringTarget: _int(rm, r'\btarget\s+(\d+)'),
    ringSize: _int(rm, r'\bof\s+(\d+)\s*\)'),
    priming: rm.toLowerCase().contains('priming'),
    underruns: _int(faults, r'\bunderruns\s+(\d+)'),
    overruns: _int(faults, r'\boverruns\s+(\d+)'),
    primes: _int(faults, r'\bprimes\s+(\d+)'),
    silentPackets: _int(faults, r'silent packets\s+(\d+)'),
    fastStarts: _int(faults, r'fast starts\s+(\d+)'),
    notReady: _int(fr, r'not ready(?:\s+at\s+sof)?\s+(\d+)'),
    sofLate: _int(fr, r'sof late(?:\s*\([^)]*\))?\s+(\d+)'),
    sofLost: _int(fr, r'\blost\s+(\d+)'),
    sofMaxIntervalUs: _int(fr, r'max interval\s+(\d+)'),
    fetchMinUs: fetch == null ? null : int.tryParse(fetch.group(1)!),
    fetchMaxUs: fetch == null ? null : int.tryParse(fetch.group(2)!),
    synthCommitMaxUs: _int(sy, r'(\d+)\s*(?:us\s+)?max'),
    offCadence: _int(sy, r'off cadence\s+(\d+)'),
    blocksLost: _int(sy, r'blocks lost\s+(\d+)'),
    cpuPercent: pct == null ? null : double.tryParse(pct.group(1)!),
    lockThreadUs: _int(cpu, r'thread\s+(\d+)\s*us'),
    lockIsrUs: _int(cpu, r'isr\s+(\d+)\s*us'),
    lines: mine,
  );
}

/// The reply to `Stct<nnn>` (set) or `Stct000` (ask): "usb audio target 96 frames (2000 us)".
final usbAudioTargetLine = RegExp(r'usb audio target\s+(\d+)\s+frames', caseSensitive: false);

int? parseUsbAudioTarget(String l) {
  final m = usbAudioTargetLine.firstMatch(l);
  return m == null ? null : int.tryParse(m.group(1)!);
}
