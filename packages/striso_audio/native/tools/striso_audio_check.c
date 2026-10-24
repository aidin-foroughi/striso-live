/* striso_audio_check: the library's self-test and two hardware checks that never play a sound.
 *
 *   striso_audio_check [--selftest] [DIR]       self-test (null backend, no real device), scratch files in DIR
 *   striso_audio_check --list                   the system's audio devices (enumeration only, nothing opened)
 *   striso_audio_check --capture SECONDS OUT.wav [--shared] [--period N] [--input NAME]
 *                                               records the Striso input (at most 5 s) to OUT.wav and
 *                                               reports its format and level; opens no output device
 *   striso_audio_check --midi-list              the system's MIDI inputs and their ids (opens nothing)
 *   striso_audio_check --midi-monitor ID SECONDS  opens that MIDI input (at most 60 s) and prints what
 *                                               reaches the sink (channel messages only)
 * Exit code: number of self-test failures, or 1 when a check fails.
 */
#include "striso_audio.h"
#include "striso_midi.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
static void nap(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void nap(int ms) {
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}
#endif

static const char* bits_name(int b) { return b == 16 ? "16-bit int" : b == 24 ? "24-bit int" : b == 32 ? "32-bit int" : b == -32 ? "32-bit float" : "unknown"; }

static int list_devices(void) {
    if (sa_init(SA_BACKEND_SYSTEM) != SA_OK) {
        fprintf(stderr, "audio system did not start\n");
        return 1;
    }
    sa_status s;
    sa_get_status(&s);
    uint32_t g = s.devices_gen;
    sa_enumerate();
    for (int i = 0; i < 400 && s.devices_gen == g; i++) {
        nap(5);
        sa_get_status(&s);
    }
    for (int cap = 1; cap >= 0; cap--) {
        int n = sa_device_count(cap);
        printf("%s (%d):\n", cap ? "inputs" : "outputs", n);
        for (int i = 0; i < n; i++) {
            sa_device d;
            if (sa_device_get(cap, i, &d) != SA_OK) continue;
            printf("  %s%s%s", d.name, d.is_default ? "  [default]" : "", d.is_striso ? "  [Striso by USB VID/PID]" : "");
            if (cap && d.native_bits) printf("  native %s %d Hz %d ch", bits_name(d.native_bits), d.native_rate, d.native_channels);
            static const char* tr[] = {"?", "USB", "Bluetooth", "built-in", "HDMI/DP", "virtual", "Thunderbolt", "PCI"};
            printf("  [%s]", d.transport >= 0 && d.transport < 8 ? tr[d.transport] : "?");
            if (d.dev_min > 0) printf("  period min %d default %d frames", d.dev_min, d.dev_default);
            printf("\n      id %s\n", d.id);
        }
    }
    sa_shutdown();
    return 0;
}

static int rd16(const unsigned char* b) { return (int)(short)(b[0] | (b[1] << 8)); }
static int rd24(const unsigned char* b) {
    int v = b[0] | (b[1] << 8) | (b[2] << 16);
    return v & 0x800000 ? v - 0x1000000 : v;
}

static void analyse(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        printf("cannot read %s\n", path);
        return;
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* b = (unsigned char*)malloc((size_t)len);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) {
        fclose(f);
        free(b);
        return;
    }
    fclose(f);
    int tag = b[20] | (b[21] << 8), ch = b[22] | (b[23] << 8), bits = b[34] | (b[35] << 8);
    unsigned rate = (unsigned)(b[24] | (b[25] << 8) | (b[26] << 16) | ((unsigned)b[27] << 24));
    long off = tag == 3 ? 58 : 44;
    unsigned dlen = (unsigned)(b[off - 4] | (b[off - 3] << 8) | (b[off - 2] << 16) | ((unsigned)b[off - 1] << 24));
    int bytes = bits / 8;
    long frames = (long)dlen / (bytes * ch);
    double peak[2] = {0, 0}, sum[2] = {0, 0};
    long nz = 0;
    for (long i = 0; i < frames; i++) {
        for (int c = 0; c < ch && c < 2; c++) {
            const unsigned char* p = b + off + (i * ch + c) * bytes;
            double v = tag == 3 ? (double)*(const float*)p : (bytes == 2 ? rd16(p) / 32768.0 : rd24(p) / 8388608.0);
            if (fabs(v) > peak[c]) peak[c] = fabs(v);
            sum[c] += v * v;
            if (v != 0) nz++;
        }
    }
    printf("file: %s, %ld bytes, format %s, %d ch, %u Hz, %d bit, %ld frames (%.2f s), data size %u (%s)\n", path, len, tag == 3 ? "float" : "PCM", ch,
           rate, bits, frames, frames / (double)rate, dlen, off + (long)dlen <= len ? "consistent" : "INCONSISTENT");
    for (int c = 0; c < ch && c < 2; c++) {
        double rms = frames ? sqrt(sum[c] / frames) : 0;
        printf("  %s: peak %.1f dBFS, RMS %.1f dBFS\n", c ? "right" : "left", peak[c] > 0 ? 20 * log10(peak[c]) : -999.0, rms > 0 ? 20 * log10(rms) : -999.0);
    }
    printf("  non-zero samples: %ld of %ld\n", nz, frames * ch);
    free(b);
}

static int capture_check(double secs, const char* out, int exclusive, int period, const char* input) {
    if (secs > 5) secs = 5;
    if (secs < 0.2) secs = 0.2;
    if (sa_init(SA_BACKEND_SYSTEM) != SA_OK) {
        fprintf(stderr, "audio system did not start\n");
        return 1;
    }
    sa_status s;
    /* monitor 0: the input only; no output device is opened */
    uint32_t gen = sa_configure(1, input, "", period, 0, exclusive);
    for (int i = 0; i < 400; i++) {
        sa_get_status(&s);
        if ((int32_t)(s.config_gen - gen) >= 0) break;
        nap(5);
    }
    if (s.capture_state != SA_DEV_RUNNING) {
        printf("input did not open: state %d, error %d, miniaudio result %d\n", s.capture_state, s.capture_error, s.capture_result);
        sa_shutdown();
        return 1;
    }
    printf("input open: %d Hz, %d ch, device format %s, %s mode, period %d frames (%.2f ms)\n", s.capture_rate, s.capture_channels, bits_name(s.capture_bits),
           s.capture_exclusive ? "exclusive" : "shared", s.capture_period, s.capture_period * 1000.0 / s.capture_rate);
    sa_record_start(out);
    nap(50);
    float pl = 0, pr = 0;
    int steps = (int)(secs * 1000 / 50);
    for (int i = 0; i < steps; i++) {
        nap(50);
        sa_get_status(&s);
        if (s.level_l > pl) pl = s.level_l;
        if (s.level_r > pr) pr = s.level_r;
    }
    sa_record_stop();
    for (int i = 0; i < 200; i++) {
        sa_get_status(&s);
        if (s.record_state != SA_REC_ON) break;
        nap(10);
    }
    printf("recorded %u frames at %s, %u dropped, record state %d error %d, %u input callbacks; meter peak L %.3f R %.3f\n", s.record_frames,
           bits_name(s.record_bits), s.record_dropped, s.record_state, s.record_error, s.capture_callbacks, pl, pr);
    sa_configure(0, "", "", period, 0, 0);
    nap(100);
    sa_shutdown();
    analyse(out);
    return s.record_error == SA_OK && s.record_frames > 0 ? 0 : 1;
}

static const char* midi_err(int32_t e) {
    switch (e) {
    case SA_OK: return "ok";
    case SA_ERR_NOT_FOUND: return "not found";
    case SA_ERR_MIDI_IN_USE: return "in use by another program";
    case SA_ERR_MIDI_OPEN: return "would not open";
    case SA_ERR_MIDI_GONE: return "gone";
    case SA_ERR_MIDI_SYSTEM: return "the MIDI system did not start";
    case SA_ERR_NOT_INITIALISED: return "not initialised";
    default: return "error";
    }
}

static int midi_list(void) {
    int32_t r = sa_midi_init();
    if (r != SA_OK) {
        fprintf(stderr, "MIDI: %s (%d)\n", midi_err(r), r);
        return 1;
    }
    uint32_t g = sa_midi_refresh();
    int n = sa_midi_count();
    printf("MIDI inputs (%d, generation %u):\n", n, g);
    for (int i = 0; i < n; i++) {
        sa_midi_device d;
        if (sa_midi_get(i, &d) != SA_OK) continue;
        printf("  %s\n      id %s%s\n", d.name, d.id, d.present ? "" : "  (gone)");
    }
    sa_midi_shutdown();
    return 0;
}

static int32_t count_sink(void* user, const uint8_t* packets, int32_t n) {
    (void)packets;
    *(volatile uint32_t*)user += (uint32_t)(n / 4);
    return n;
}

/* opens one input for at most 60 s and prints every channel message the sink gets */
static int midi_monitor(const char* id, double secs) {
    if (secs > 60) secs = 60;
    if (sa_midi_init() != SA_OK) {
        fprintf(stderr, "MIDI did not start\n");
        return 1;
    }
    sa_midi_refresh();
    static volatile uint32_t packets = 0;
    sa_midi_set_sink(count_sink, (void*)&packets);
    int32_t r = sa_midi_open(id);
    if (r != SA_OK) {
        fprintf(stderr, "%s: %s (%d)\n", id, midi_err(r), r);
        sa_midi_shutdown();
        return 1;
    }
    printf("%s open for %.0f s\n", id, secs);
    fflush(stdout);
    const int64_t t0 = sa_clock_us();
    uint32_t shown = 0, loops = 0;
    while (sa_clock_us() - t0 < (int64_t)(secs * 1e6)) {
        sa_midi_event ev[256];
        int k;
        while ((k = sa_midi_events(ev, 256)) > 0) {
            for (int i = 0; i < k; i++) {
                printf("%10.3f  slot %d  %02X %02X", (ev[i].t_us - t0) / 1e6, ev[i].device, ev[i].bytes[0], ev[i].bytes[1]);
                if (ev[i].len == 3) printf(" %02X", ev[i].bytes[2]);
                printf("\n");
            }
            shown += (uint32_t)k;
        }
        fflush(stdout);
        nap(20);
        if (++loops % 50 == 0) sa_midi_refresh(); /* once a second: an unplug closes it */
    }
    sa_midi_set_sink(NULL, NULL);
    printf("%u messages shown, %u packets to the sink, %u monitor events dropped\n", shown, packets, sa_midi_events_lost());
    sa_midi_shutdown();
    return 0;
}

int main(int argc, char** argv) {
    if (argc >= 2 && strcmp(argv[1], "--list") == 0) return list_devices();
    if (argc >= 2 && strcmp(argv[1], "--midi-list") == 0) return midi_list();
    if (argc >= 4 && strcmp(argv[1], "--midi-monitor") == 0) return midi_monitor(argv[2], atof(argv[3]));
    if (argc >= 4 && strcmp(argv[1], "--capture") == 0) {
        int exclusive = 1, period = 128;
        const char* input = "";
        for (int i = 4; i < argc; i++) {
            if (strcmp(argv[i], "--shared") == 0) exclusive = 0;
            else if (strcmp(argv[i], "--period") == 0 && i + 1 < argc) period = atoi(argv[++i]);
            else if (strcmp(argv[i], "--input") == 0 && i + 1 < argc) input = argv[++i];
        }
        return capture_check(atof(argv[2]), argv[3], exclusive, period, input);
    }
    const char* dir = ".";
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], "--selftest") != 0) dir = argv[i];
    static char report[65536];
    int fails = sa_selftest(dir, report, (int)sizeof(report));
    fputs(report, stdout);
    return fails;
}
