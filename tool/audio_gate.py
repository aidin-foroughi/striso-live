#!/usr/bin/env python3
"""The install gate for striso_audio: what the output device would get, from a reference build and
a candidate build, for the same known input, through the real audio path on miniaudio's null
backend (no device is opened). Run before installing any build:

    python tool/audio_gate.py <reference striso_audio.dll|.dylib> <candidate ...> [--json report.json]

The reference is the last build the user approved by ear (the release); both need the device tap
(sa_probe tap 2: every gain applied, before the conversion to the device's format) and
sa_test_input. Each build runs in its own process, once per scenario:

  monitor  the board's USB audio monitor (Through PC): a 440 Hz sine of amplitude 0.25 as the
           input, the passthrough to the output at the gain;
  virtual  Virtual: a 440 Hz sine of 0.25 as the output's source (sa_set_source, as the virtual
           board renders), at the gain;

each at gain -6 dB (the default) and 0 dB, with the output asked shared and exclusive (the null
backend opens it shared either way; a build that simulates an exclusive device's volume,
sa_test_output_volume, is measured at that volume too, and must equal its shared output times the
volume). Per run: the level (RMS, dBFS), the peak, and the sine's distortion (the residual after
fitting a 440 Hz sine, dB under it). The gate fails when the candidate's level or peak differs from
the reference's by more than 0.1 / 0.2 dB, its distortion is worse by more than 3 dB (above -90 dB), or (virtual)
its samples differ from the reference's.
Exit status 0: pass, 1: fail, 2: a build could not run.
"""
import ctypes
import json
import math
import os
import subprocess
import sys
import time

SECONDS = 2.0
SETTLE = 0.5
HZ = 440.0
AMP = 0.25
# distortion below the floor is the measurement's own (float rounding, the passthrough's resampler);
# above it, worse by more than the tolerance fails (overdrive or clipping is tens of dB worse)
DIST_FLOOR = -90.0
DIST_TOL = 3.0


def run_one(dll, scenario, gain_db, exclusive, volume):
    """In a child process: one build, one scenario; returns the device tap (interleaved stereo)."""
    os.add_dll_directory(os.path.dirname(dll)) if hasattr(os, 'add_dll_directory') else None
    lib = ctypes.CDLL(dll)
    SRC = ctypes.CFUNCTYPE(ctypes.c_int32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int32, ctypes.c_int32)
    phase = [0.0]

    def src(user, out, frames, rate):
        step = 2 * math.pi * HZ / rate
        p = phase[0]
        for i in range(frames):
            v = AMP * math.sin(p)
            out[2 * i] = v
            out[2 * i + 1] = v
            p += step
        phase[0] = p
        return frames

    cb = SRC(src)
    lib.sa_set_gain.argtypes = [ctypes.c_float]
    lib.sa_test_input.argtypes = [ctypes.c_float, ctypes.c_float]
    lib.sa_probe_audio.argtypes = [ctypes.c_int32, ctypes.POINTER(ctypes.c_float), ctypes.c_int32, ctypes.POINTER(ctypes.c_int64), ctypes.POINTER(ctypes.c_int32)]
    if lib.sa_init(1) != 0:
        raise SystemExit('sa_init failed')
    has_volume = hasattr(lib, 'sa_test_output_volume')
    if has_volume:
        lib.sa_test_output_volume.argtypes = [ctypes.c_float]
        lib.sa_test_output_volume(ctypes.c_float(volume if exclusive else -1.0))
    elif exclusive and volume != 1.0:
        print(json.dumps({'skip': 'no sa_test_output_volume'}))
        return
    lib.sa_set_gain(ctypes.c_float(10 ** (gain_db / 20)))
    flags = 2 if exclusive else 0
    if scenario == 'monitor':
        lib.sa_test_input(ctypes.c_float(HZ), ctypes.c_float(AMP))
        monitor, input_name = 1, b'NULL Capture Device'  # the null backend's input ("" asks for the Striso)
    else:
        lib.sa_set_source(cb, None)
        flags |= 4  # the output alone
        monitor, input_name = 0, b''
    lib.sa_probe(1)
    lib.sa_configure(1, input_name, b'', 64, monitor, flags)
    samples = []
    buf = (ctypes.c_float * (2 * 48000))()
    first, sess = ctypes.c_int64(), ctypes.c_int32()
    t_end = time.time() + SECONDS + 1.0
    while time.time() < t_end:
        n = lib.sa_probe_audio(2, buf, 48000, ctypes.byref(first), ctypes.byref(sess))
        samples.extend(buf[i] for i in range(2 * n))
        time.sleep(0.05)
    lib.sa_configure(0, b'', b'', 64, 0, 0)
    time.sleep(0.2)
    lib.sa_set_source(None, None)
    lib.sa_shutdown()
    print(json.dumps({'samples': samples}))


def _fit(block, freq, rate):
    """Least squares a sin + b cos at freq: the sine's RMS and the residual's RMS."""
    w = 2 * math.pi * freq / rate
    ss = sc = cc = ys = yc = 0.0
    for i, v in enumerate(block):
        sn, cs = math.sin(w * i), math.cos(w * i)
        ss += sn * sn
        sc += sn * cs
        cc += cs * cs
        ys += v * sn
        yc += v * cs
    det = ss * cc - sc * sc
    if not det:
        return 0.0, 0.0
    a = (ys * cc - yc * sc) / det
    b = (yc * ss - ys * sc) / det
    res = sum((v - (a * math.sin(w * i) + b * math.cos(w * i))) ** 2 for i, v in enumerate(block))
    return math.sqrt((a * a + b * b) / 2), math.sqrt(res / len(block))


def _freq(block, rate):
    """The sine's frequency from its rising zero crossings (interpolated)."""
    xs = []
    for i in range(1, len(block)):
        a, b = block[i - 1], block[i]
        if a < 0 <= b and b != a:
            xs.append(i - 1 + (-a) / (b - a))
    if len(xs) < 3:
        return HZ
    return rate * (len(xs) - 1) / (xs[-1] - xs[0])


def measure(x, rate=48000):
    """Level, peak and distortion of the left channel after the settle time. Distortion: per block
    of 0.1 s, the residual after fitting a sine at the block's own frequency (the passthrough
    resamples by its drift servo), dB under the sine; the median over the blocks (a block with a
    dropout or the priming is an outlier, not the sound)."""
    left = x[0::2][int(SETTLE * rate):]
    if len(left) < rate // 2:
        return None
    n = len(left)
    rms = math.sqrt(sum(v * v for v in left) / n)
    peak = max(abs(v) for v in left)
    db = lambda v: 20 * math.log10(v) if v > 0 else -300.0
    dist = []
    k = rate // 10
    for o in range(0, n - k + 1, k):
        block = left[o:o + k]
        if max(abs(v) for v in block) < 1e-6:
            continue
        sine, resid = _fit(block, _freq(block, rate), rate)
        if sine > 0:
            dist.append(db(resid) - db(sine))
    dist.sort()
    return {'rms_db': db(rms), 'peak_db': db(peak), 'distortion_db': dist[len(dist) // 2] if dist else 0.0, 'frames': n}


def child_run(dll, scenario, gain_db, exclusive, volume):
    r = subprocess.run([sys.executable, __file__, '--child', dll, scenario, str(gain_db), str(int(exclusive)), str(volume)],
                       capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f'{os.path.basename(dll)} {scenario}: {r.stderr.strip()[-400:]}')
    return json.loads(r.stdout.strip().splitlines()[-1])


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--child':
        _, _, dll, scenario, gain_db, exclusive, volume = sys.argv
        run_one(dll, scenario, float(gain_db), exclusive == '1', float(volume))
        return 0
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        print(__doc__)
        return 2
    ref, cand = (os.path.abspath(a) for a in args)
    report_path = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    report, ok = [], True
    cases = [(s, g, e, v) for s in ('monitor', 'virtual') for g in (-6.0, 0.0) for e, v in ((False, 1.0), (True, 1.0), (True, 0.3))]
    for scenario, gain_db, exclusive, volume in cases:
        name = f'{scenario} {gain_db:+.0f} dB {"exclusive" if exclusive else "shared"}{f" volume {volume}" if exclusive and volume != 1.0 else ""}'
        try:
            r = child_run(ref, scenario, gain_db, exclusive, volume)
            c = child_run(cand, scenario, gain_db, exclusive, volume)
        except Exception as e:  # noqa: BLE001
            print(f'ERROR {name}: {e}')
            return 2
        if 'skip' in r or 'skip' in c:
            # the reference cannot simulate the volume: the candidate's exclusive output must be its
            # own shared output times the volume (what the Windows mixer makes of shared)
            if 'skip' in c:
                print(f'skip  {name}: {c["skip"]}')
                continue
            shared = child_run(cand, scenario, gain_db, False, 1.0)
            ms, mc = measure(shared['samples']), measure(c['samples'])
            want = ms['rms_db'] + 20 * math.log10(volume)
            good = abs(mc['rms_db'] - want) <= 0.1 and mc['distortion_db'] <= max(ms['distortion_db'], DIST_FLOOR) + DIST_TOL
            ok &= good
            print(f'{"PASS" if good else "FAIL"}  {name}: candidate {mc["rms_db"]:.2f} dB, its shared x volume {want:.2f} dB')
            report.append({'case': name, 'pass': good, 'candidate': mc, 'shared_times_volume_db': want})
            continue
        mr, mc = measure(r['samples']), measure(c['samples'])
        if mr is None or mc is None:
            print(f'FAIL  {name}: too few frames (reference {len(r["samples"])}, candidate {len(c["samples"])})')
            ok = False
            continue
        good = abs(mc['rms_db'] - mr['rms_db']) <= 0.1 and abs(mc['peak_db'] - mr['peak_db']) <= 0.2 and mc['distortion_db'] <= max(mr['distortion_db'], DIST_FLOOR) + DIST_TOL
        diff = None
        if scenario == 'virtual':
            k = min(len(r['samples']), len(c['samples']), 2 * 48000)
            diff = max((abs(a - b) for a, b in zip(r['samples'][:k], c['samples'][:k])), default=0.0)
            good &= diff <= 1e-6
        ok &= good
        extra = f', samples differ by {diff:.2e} at most' if diff is not None else ''
        print(f'{"PASS" if good else "FAIL"}  {name}: level {mr["rms_db"]:.2f} -> {mc["rms_db"]:.2f} dB, peak {mr["peak_db"]:.2f} -> '
              f'{mc["peak_db"]:.2f} dB, distortion {mr["distortion_db"]:.1f} -> {mc["distortion_db"]:.1f} dB{extra}')
        report.append({'case': name, 'pass': good, 'reference': mr, 'candidate': mc, 'max_sample_diff': diff})
    if report_path:
        with open(report_path, 'w', encoding='utf-8') as f:
            json.dump({'reference': ref, 'candidate': cand, 'pass': ok, 'cases': report}, f, indent=1)
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
