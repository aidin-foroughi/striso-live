/* sa_selftest: the passthrough math on a simulated clock, the resampler's response, the WAV
 * writer byte for byte, and a session on miniaudio's null backend through the public API. Opens
 * no real device. */
#include "sa_core.h"
#include "sa_platform.h"
#include "striso_audio.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int sa_internal_inited(void);

static char* g_rep;
static int g_rep_size, g_rep_len, g_fail;

static void say(const char* fmt, ...) {
    if (!g_rep || g_rep_len >= g_rep_size - 1) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(g_rep + g_rep_len, (size_t)(g_rep_size - g_rep_len), fmt, ap);
    va_end(ap);
    if (n > 0) g_rep_len += n;
    if (g_rep_len > g_rep_size - 1) g_rep_len = g_rep_size - 1;
}

static void check(int ok, const char* what) {
    say("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) g_fail++;
}

/* ---------------------------------------------------------------- ring */

static void test_ring(void) {
    sa_ring rb;
    int ok = sa_ring_init(&rb, 100) == 0 && rb.cap == 128;
    float in[2 * 50], out[2 * 50];
    uint32_t next_w = 0, next_r = 0;
    for (int round = 0; round < 200 && ok; round++) {
        uint32_t nw = (uint32_t)(round * 7 % 50) + 1;
        for (uint32_t i = 0; i < nw; i++) {
            in[2 * i] = (float)(next_w + i);
            in[2 * i + 1] = -(float)(next_w + i);
        }
        uint32_t w = sa_ring_write(&rb, in, nw);
        next_w += w;
        uint32_t nr = (uint32_t)(round * 5 % 47) + 1;
        uint32_t r = sa_ring_read(&rb, out, nr);
        for (uint32_t i = 0; i < r; i++)
            if (out[2 * i] != (float)(next_r + i) || out[2 * i + 1] != -(float)(next_r + i)) ok = 0;
        next_r += r;
        if (sa_ring_fill(&rb) != next_w - next_r || sa_ring_fill(&rb) > rb.cap) ok = 0;
    }
    /* full ring refuses the rest */
    sa_ring_skip(&rb, rb.cap);
    float big[2 * 200] = {0};
    ok = ok && sa_ring_write(&rb, big, 200) == rb.cap && sa_ring_write(&rb, big, 1) == 0;
    sa_ring_free(&rb);
    check(ok, "ring: wrap-around order, fill, full ring refuses frames");
}

/* ---------------------------------------------------------------- simulation */

typedef struct {
    const char* name;
    double ppm;       /* input clock vs nominal */
    uint32_t pc, pp;  /* input and output periods */
    double fs_out;
    double jitter_us; /* callbacks arrive up to this late */
    int burst_every;  /* every n-th input block arrives together with the next (0: never) */
    double stall_at, stall_len; /* output callbacks stop (s) */
    double gap_at, gap_len;     /* input stops (s) */
    double seconds;
    double freq;
    double fixed_ratio; /* > 0: no servo */
} sim_cfg;

typedef struct {
    uint32_t underruns, underruns_late, resyncs, overruns;
    double max_d2;      /* largest second difference of the output: clicks */
    double max_d2_t;    /* when */
    double under_t[4];  /* when the first underruns happened */
    double final_ppm;
    double ring_ms_late, target_ms_late;
    int streaming;
    double* capture; /* optional: output samples (left) after `capture_from` */
    long capture_n, capture_max;
    double capture_from;
} sim_res;

static uint32_t lcg(uint32_t* s) {
    *s = *s * 1664525u + 1013904223u;
    return *s >> 8;
}

static void simulate(const sim_cfg* c, sim_res* r) {
    sa_pass p;
    double fs_in = 48000;
    if (sa_pass_init(&p, fs_in, c->fs_out, c->pc) != 0) {
        r->underruns = 9999;
        return;
    }
    p.fixed_ratio = c->fixed_ratio;
    uint32_t seed = 12345;
    double fs_cap = fs_in * (1 + c->ppm * 1e-6);
    double t_cap_nom = 0.0001, t_play_nom = 0.0007;
    double t_cap = t_cap_nom, t_play = t_play_nom;
    double phase = 0, dph = 2 * M_PI * c->freq / fs_in;
    float* in = (float*)malloc(sizeof(float) * 2 * 2 * c->pc);
    float* out = (float*)malloc(sizeof(float) * 2 * c->pp);
    double y1 = 0, y2 = 0;
    long nout = 0;
    long block = 0;
    double warm = c->seconds * 0.4;
    double ring_sum = 0, target_sum = 0, ppm_sum = 0;
    long late_n = 0;
    while (t_cap < c->seconds || t_play < c->seconds) {
        if (t_cap <= t_play) {
            int deliver = 1, frames = (int)c->pc;
            block++;
            if (c->burst_every && block % c->burst_every == 0) deliver = 0; /* comes with the next */
            if (c->burst_every && block % c->burst_every == 1 && block > 1) frames = 2 * (int)c->pc;
            int in_gap = c->gap_len > 0 && t_cap_nom >= c->gap_at && t_cap_nom < c->gap_at + c->gap_len;
            if (deliver) {
                for (int i = 0; i < frames; i++) {
                    float v = (float)(0.5 * sin(phase));
                    in[2 * i] = v;
                    in[2 * i + 1] = -v;
                    phase += dph;
                    if (phase > 2 * M_PI) phase -= 2 * M_PI;
                }
                if (!in_gap) sa_pass_push(&p, in, (uint32_t)frames, (uint32_t)(t_cap * 1e6));
            } else if (in_gap) {
                /* nothing */
            }
            t_cap_nom += c->pc / fs_cap;
            t_cap = t_cap_nom + (lcg(&seed) % 1000) / 1000.0 * c->jitter_us * 1e-6;
        } else {
            int stalled = c->stall_len > 0 && t_play_nom >= c->stall_at && t_play_nom < c->stall_at + c->stall_len;
            if (!stalled) {
                uint32_t before = sa_ld(&p.underruns);
                sa_pass_pull(&p, out, c->pp, (uint32_t)(t_play * 1e6), 1.0f);
                uint32_t now_u = sa_ld(&p.underruns);
                if (t_play_nom > warm && now_u != before) r->underruns_late += now_u - before;
                if (now_u != before && now_u <= 4) r->under_t[now_u - 1] = t_play_nom;
                for (uint32_t i = 0; i < c->pp; i++) {
                    double y = out[2 * i];
                    if (nout >= 2) {
                        double d2 = fabs(y - 2 * y1 + y2);
                        if (d2 > r->max_d2) {
                            r->max_d2 = d2;
                            r->max_d2_t = t_play_nom + i / c->fs_out;
                        }
                    }
                    if (r->capture && t_play_nom >= r->capture_from && r->capture_n < r->capture_max) r->capture[r->capture_n++] = y;
                    y2 = y1;
                    y1 = y;
                    nout++;
                }
                if (t_play_nom > warm) {
                    ring_sum += sa_ldf(&p.st_ring) / fs_in * 1000;
                    target_sum += sa_ldf(&p.st_target) / fs_in * 1000;
                    ppm_sum += sa_ldf(&p.st_ppm);
                    late_n++;
                }
            }
            t_play_nom += c->pp / c->fs_out;
            t_play = t_play_nom + (lcg(&seed) % 1000) / 1000.0 * c->jitter_us * 1e-6;
        }
    }
    r->underruns = sa_ld(&p.underruns);
    r->resyncs = sa_ld(&p.resyncs);
    r->overruns = sa_ld(&p.overruns);
    r->final_ppm = late_n ? ppm_sum / late_n : sa_ldf(&p.st_ppm);
    r->streaming = (int)sa_ld(&p.streaming);
    r->ring_ms_late = late_n ? ring_sum / late_n : 0;
    r->target_ms_late = late_n ? target_sum / late_n : 0;
    free(in);
    free(out);
    sa_pass_free(&p);
}

static void test_drift(void) {
    const sim_cfg cases[] = {
        {"same clock, 128/128", 0, 128, 128, 48000, 300, 0, 0, 0, 0, 0, 40, 440, 0},
        {"+100 ppm, 480/128 (shared-mode input)", 100, 480, 128, 48000, 800, 0, 0, 0, 0, 0, 40, 440, 0},
        {"-250 ppm, 64/64", -250, 64, 64, 48000, 200, 0, 0, 0, 0, 0, 40, 440, 0},
        {"+1000 ppm, 256/64", 1000, 256, 64, 48000, 500, 0, 0, 0, 0, 0, 40, 440, 0},
        {"-1000 ppm, 128/512", -1000, 128, 512, 48000, 500, 0, 0, 0, 0, 0, 40, 440, 0},
        {"+50 ppm, 48 kHz in, 44.1 kHz out", 50, 128, 128, 44100, 300, 0, 0, 0, 0, 0, 40, 440, 0},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        sim_res r;
        memset(&r, 0, sizeof(r));
        simulate(&cases[i], &r);
        char what[256];
        snprintf(what, sizeof(what),
                 "drift %s: %u underruns (%u after settling), %u resyncs, servo %+.0f ppm (mean), ring %.2f ms (target %.2f), max step %.4f",
                 cases[i].name, r.underruns, r.underruns_late, r.resyncs, r.final_ppm, r.ring_ms_late, r.target_ms_late, r.max_d2);
        int ok = r.underruns_late == 0 && r.resyncs == 0 && r.overruns == 0 && r.streaming && r.max_d2 < 0.01 && fabs(r.final_ppm - cases[i].ppm) < 20 + 0.1 * fabs(cases[i].ppm);
        check(ok, what);
    }
}

static void test_glitches(void) {
    sim_res r;
    sim_cfg burst = {"bursty input", 80, 128, 128, 48000, 300, 37, 0, 0, 0, 0, 90, 440, 0};
    memset(&r, 0, sizeof(r));
    simulate(&burst, &r);
    char what[256];
    snprintf(what, sizeof(what), "bursts (every 37th block late by a period): %u underruns (%u after settling; at %.2f %.2f %.2f s), max step %.4f",
             r.underruns, r.underruns_late, r.under_t[0], r.under_t[1], r.under_t[2], r.max_d2);
    check(r.underruns <= 4 && r.underruns_late == 0 && r.max_d2 < 0.01 && r.streaming, what);

    sim_cfg stall = {"output stall", 30, 128, 128, 48000, 300, 0, 10, 0.12, 0, 0, 40, 440, 0};
    memset(&r, 0, sizeof(r));
    simulate(&stall, &r);
    snprintf(what, sizeof(what), "output stalls 120 ms: %u resync, %u underruns after settling, max step %.4f (faded)", r.resyncs, r.underruns_late, r.max_d2);
    check(r.resyncs >= 1 && r.underruns_late == 0 && r.max_d2 < 0.01 && r.streaming, what);

    sim_cfg gap = {"input gap", -30, 128, 128, 48000, 300, 0, 0, 0, 10, 0.3, 40, 440, 0};
    memset(&r, 0, sizeof(r));
    simulate(&gap, &r);
    snprintf(what, sizeof(what), "input stops 300 ms (replug): %u underruns, back to streaming %s, max step %.4f at %.3f s (faded)", r.underruns,
             r.streaming ? "yes" : "no", r.max_d2, r.max_d2_t);
    check(r.underruns >= 1 && r.max_d2 < 0.01 && r.streaming, what);
}

/* least-squares sine fit at a known frequency: gain (dB re amplitude a0) and SNR */
static void fit_sine(const double* y, long n, double w, double a0, double* gain_db, double* snr_db) {
    double ss = 0, cc = 0, sc = 0, ys = 0, yc = 0;
    for (long i = 0; i < n; i++) {
        double s = sin(w * i), c = cos(w * i);
        ss += s * s;
        cc += c * c;
        sc += s * c;
        ys += y[i] * s;
        yc += y[i] * c;
    }
    double det = ss * cc - sc * sc;
    double a = (ys * cc - yc * sc) / det, b = (yc * ss - ys * sc) / det;
    double sig = 0, res = 0;
    for (long i = 0; i < n; i++) {
        double f = a * sin(w * i) + b * cos(w * i);
        sig += f * f;
        res += (y[i] - f) * (y[i] - f);
    }
    *gain_db = 20 * log10(sqrt(a * a + b * b) / a0);
    *snr_db = 10 * log10(sig / (res > 1e-30 ? res : 1e-30));
}

static void test_resampler(void) {
    struct {
        double fs_out, ratio, freq, max_db, min_snr;
    } cases[] = {
        {48000, 1.0001, 1000, 0.02, 90},  {48000, 1.0001, 10000, 0.05, 80}, {48000, 1.0001, 18000, 0.25, 70},
        {48000, 0.9997, 15000, 0.15, 75}, {44100, 48000.0 / 44100, 1000, 0.02, 85}, {44100, 48000.0 / 44100, 16000, 0.3, 70},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        sim_cfg c = {"fixed", 0, 128, 128, cases[i].fs_out, 0, 0, 0, 0, 0, 0, 1.5, cases[i].freq, cases[i].ratio};
        /* the input arrives exactly as fast as the fixed ratio consumes it */
        c.ppm = (cases[i].ratio * cases[i].fs_out / 48000 - 1) * 1e6;
        sim_res r;
        memset(&r, 0, sizeof(r));
        r.capture_max = 32768;
        r.capture = (double*)malloc(sizeof(double) * (size_t)r.capture_max);
        r.capture_from = 0.5;
        simulate(&c, &r);
        double g = 0, snr = 0;
        double w = 2 * M_PI * cases[i].freq / 48000 * cases[i].ratio;
        if (r.capture_n > 8192) fit_sine(r.capture, r.capture_n, w, 0.5, &g, &snr);
        char what[200];
        snprintf(what, sizeof(what), "resampler %.0f Hz at ratio %.5f (%.1f kHz out): gain %+.3f dB, SNR %.1f dB", cases[i].freq, cases[i].ratio,
                 cases[i].fs_out / 1000, g, snr);
        check(r.capture_n > 8192 && fabs(g) <= cases[i].max_db && snr >= cases[i].min_snr && r.underruns_late == 0, what);
        free(r.capture);
    }
}

/* ---------------------------------------------------------------- WAV */

static unsigned char* slurp(const char* path, long* len) {
    FILE* f = sa_fopen_utf8(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* b = (unsigned char*)malloc((size_t)*len + 1);
    if (b && fread(b, 1, (size_t)*len, f) != (size_t)*len) {
        free(b);
        b = NULL;
    }
    fclose(f);
    return b;
}

static uint32_t le32(const unsigned char* b) { return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24); }
static uint32_t le16(const unsigned char* b) { return (uint32_t)b[0] | ((uint32_t)b[1] << 8); }

static void test_wav(const char* dir) {
    char path[1024];
    /* 24 bit: exact values, clipping, little-endian 3-byte packing */
    snprintf(path, sizeof(path), "%s/selftest_24.wav", dir);
    const float v24[] = {0.0f, 1.0f / 8388608, -1.0f / 8388608, -1.0f, 8388607.0f / 8388608, 1.5f, -2.0f, 0.5f};
    sa_wav w;
    FILE* f = sa_fopen_utf8(path, "wb");
    int ok = f && sa_wav_begin(&w, f, 48000, 2, 24) == SA_OK;
    ok = ok && sa_wav_write(&w, v24, 4) == SA_OK && sa_wav_update_header(&w) == SA_OK && sa_wav_write(&w, v24, 4) == SA_OK;
    ok = ok && sa_wav_end(&w) == SA_OK;
    long len = 0;
    unsigned char* b = ok ? slurp(path, &len) : NULL;
    if (b) {
        ok = len == 44 + 8 * 6 && memcmp(b, "RIFF", 4) == 0 && le32(b + 4) == (uint32_t)len - 8 && memcmp(b + 8, "WAVE", 4) == 0 &&
             memcmp(b + 12, "fmt ", 4) == 0 && le32(b + 16) == 16 && le16(b + 20) == 1 && le16(b + 22) == 2 && le32(b + 24) == 48000 &&
             le32(b + 28) == 48000 * 6 && le16(b + 32) == 6 && le16(b + 34) == 24 && memcmp(b + 36, "data", 4) == 0 && le32(b + 40) == 48;
        const unsigned char want[24] = {0, 0, 0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0, 0, 0x80, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0x7F, 0, 0, 0x80, 0, 0, 0x40};
        ok = ok && memcmp(b + 44, want, 24) == 0 && memcmp(b + 68, want, 24) == 0;
        free(b);
    } else {
        ok = 0;
    }
    check(ok, "wav 24 bit: header (PCM, 2 ch, 48 kHz, 6-byte frames), sizes after a mid-way update, 3-byte LE packing, clipping");

    /* 16 bit */
    snprintf(path, sizeof(path), "%s/selftest_16.wav", dir);
    const float v16[] = {0.0f, 1.0f / 32768, -1.0f, 0.99999f, 0.25f, -0.25f};
    f = sa_fopen_utf8(path, "wb");
    ok = f && sa_wav_begin(&w, f, 48000, 2, 16) == SA_OK && sa_wav_write(&w, v16, 3) == SA_OK && sa_wav_end(&w) == SA_OK;
    b = ok ? slurp(path, &len) : NULL;
    if (b) {
        const unsigned char want[12] = {0, 0, 1, 0, 0, 0x80, 0xFF, 0x7F, 0, 0x20, 0, 0xE0};
        ok = len == 44 + 12 && le16(b + 20) == 1 && le16(b + 32) == 4 && le16(b + 34) == 16 && le32(b + 40) == 12 && memcmp(b + 44, want, 12) == 0;
        free(b);
    } else {
        ok = 0;
    }
    check(ok, "wav 16 bit: header and samples");

    /* float, with its fact chunk */
    snprintf(path, sizeof(path), "%s/selftest_f32.wav", dir);
    const float vf[] = {0.25f, -0.5f, 1.25f, 0.0f};
    f = sa_fopen_utf8(path, "wb");
    ok = f && sa_wav_begin(&w, f, 48000, 2, -32) == SA_OK && sa_wav_write(&w, vf, 2) == SA_OK && sa_wav_end(&w) == SA_OK;
    b = ok ? slurp(path, &len) : NULL;
    if (b) {
        float back[4];
        memcpy(back, b + 58, 16);
        ok = len == 58 + 16 && le32(b + 4) == (uint32_t)len - 8 && le32(b + 16) == 18 && le16(b + 20) == 3 && le16(b + 34) == 32 &&
             memcmp(b + 38, "fact", 4) == 0 && le32(b + 46) == 2 && memcmp(b + 50, "data", 4) == 0 && le32(b + 54) == 16 && memcmp(back, vf, 16) == 0;
        free(b);
    } else {
        ok = 0;
    }
    check(ok, "wav float: format 3, fact chunk with the frame count, samples unchanged");

    /* mono 24 bit, odd data: a pad byte the data size leaves out */
    snprintf(path, sizeof(path), "%s/selftest_pad.wav", dir);
    const float vm[] = {0.1f};
    f = sa_fopen_utf8(path, "wb");
    ok = f && sa_wav_begin(&w, f, 48000, 1, 24) == SA_OK && sa_wav_write(&w, vm, 1) == SA_OK && sa_wav_end(&w) == SA_OK;
    b = ok ? slurp(path, &len) : NULL;
    if (b) {
        ok = len == 44 + 3 + 1 && le32(b + 40) == 3 && le32(b + 4) == (uint32_t)len - 8;
        free(b);
    } else {
        ok = 0;
    }
    check(ok, "wav odd data size: pad byte, RIFF size includes it, data size does not");
}

/* ---------------------------------------------------------------- null-backend session */

static int wait_for(int (*cond)(const sa_status*), int ms, sa_status* s) {
    for (int t = 0; t < ms; t += 5) {
        sa_get_status(s);
        if (cond(s)) return 1;
        sa_sleep_ms(5);
    }
    sa_get_status(s);
    return cond(s);
}

static uint32_t g_gen, g_dev_gen;
static int applied(const sa_status* s) { return (int32_t)(s->config_gen - g_gen) >= 0; }
static int enumerated(const sa_status* s) { return s->devices_gen != g_dev_gen; }
static int both_running(const sa_status* s) { return applied(s) && s->capture_state == SA_DEV_RUNNING && s->playback_state == SA_DEV_RUNNING; }
static int streaming(const sa_status* s) { return s->streaming != 0 && s->playback_callbacks > 10; }
static int rec_done(const sa_status* s) { return s->record_state != SA_REC_ON; }
static int rec_on(const sa_status* s) { return s->record_state == SA_REC_ON; }

static void test_session(const char* dir) {
    if (sa_internal_inited()) {
        check(0, "session: the library is in use (sa_init was called): skipped");
        return;
    }
    sa_status s;
    check(sa_sizeof_status() == (int32_t)sizeof(sa_status) && sizeof(sa_status) % 4 == 0 && sizeof(sa_device) == 256 + 5 * 4, "struct sizes");
    if (sa_init(SA_BACKEND_NULL) != SA_OK) {
        check(0, "session: null backend init");
        return;
    }
    sa_get_status(&s);
    g_dev_gen = s.devices_gen;
    sa_enumerate();
    int ok = wait_for(enumerated, 2000, &s);
    int nc = sa_device_count(1), np = sa_device_count(0);
    sa_device cap;
    memset(&cap, 0, sizeof(cap));
    ok = ok && nc >= 1 && np >= 1 && sa_device_get(1, 0, &cap) == SA_OK && cap.name[0];
    check(ok, "session: enumeration on the null backend");
    if (!ok) {
        sa_shutdown();
        return;
    }
    say("      input \"%s\", %d inputs, %d outputs\n", cap.name, nc, np);

    g_gen = sa_configure(1, "no such input", "", 256, 1, 0);
    wait_for(applied, 2000, &s);
    check(s.capture_state == SA_DEV_FAILED && s.capture_error == SA_ERR_NOT_FOUND, "session: a missing input fails with not found");

    sa_set_gain(0.5f);
    g_gen = sa_configure(1, cap.name, "", 256, 1, 0);
    ok = wait_for(both_running, 3000, &s);
    check(ok && s.capture_rate == 48000 && s.playback_rate > 0, "session: input and output open (duplex passthrough)");
    ok = wait_for(streaming, 3000, &s);
    char what[200];
    snprintf(what, sizeof(what), "session: streaming, latency %.1f ms (ring %.1f, target %.1f), gain %.2f", s.latency_ms, s.ring_ms, s.target_ms, s.gain);
    check(ok && s.latency_ms > 0 && fabsf(s.gain - 0.5f) < 1e-6f, what);

    char path[1024];
    snprintf(path, sizeof(path), "%s/selftest_session.wav", dir);
    sa_record_start(path);
    ok = wait_for(rec_on, 2000, &s);
    uint32_t t0 = sa_now_us();
    sa_sleep_ms(700);
    sa_record_stop();
    ok = ok && wait_for(rec_done, 2000, &s);
    double secs = (sa_now_us() - t0) / 1e6;
    long len = 0;
    unsigned char* b = slurp(path, &len);
    int bytes = s.record_bits == 16 ? 2 : (s.record_bits == 24 ? 3 : 4);
    int hdr = s.record_bits < 0 ? 58 : 44;
    ok = ok && b && s.record_state == SA_REC_IDLE && s.record_error == SA_OK && len == hdr + (long)s.record_frames * 2 * bytes &&
         le32(b + hdr - 4) == s.record_frames * 2 * (uint32_t)bytes && s.record_frames > 0.5 * 48000 * 0.7 && s.record_frames < 48000 * (secs + 0.3);
    snprintf(what, sizeof(what), "session: recorded %u frames in %.2f s at %d bit, file %ld bytes, header matches", s.record_frames, secs, s.record_bits, len);
    check(ok, what);
    free(b);

    /* input only (recording without monitoring): the output closes, the input stays */
    uint32_t cb = s.capture_callbacks;
    g_gen = sa_configure(1, cap.name, "", 256, 0, 0);
    wait_for(applied, 2000, &s);
    sa_sleep_ms(100);
    sa_get_status(&s);
    check(s.capture_state == SA_DEV_RUNNING && s.playback_state == SA_DEV_CLOSED && s.capture_callbacks > cb, "session: monitor off keeps the input running");

    g_gen = sa_configure(0, "", "", 256, 0, 0);
    wait_for(applied, 2000, &s);
    check(s.capture_state == SA_DEV_CLOSED && s.playback_state == SA_DEV_CLOSED, "session: run 0 closes everything");
    sa_record_start(path);
    sa_sleep_ms(80);
    sa_get_status(&s);
    check(s.record_state == SA_REC_STOPPED && s.record_error == SA_ERR_NOT_RUNNING, "session: recording without the input is refused");
    sa_shutdown();
    sa_get_status(&s);
    check(s.initialised == 0, "session: shutdown");
}

SA_API int32_t sa_selftest(const char* dir, char* report, int32_t report_size) {
    g_rep = report;
    g_rep_size = report_size;
    g_rep_len = 0;
    g_fail = 0;
    if (report && report_size > 0) report[0] = 0;
    const char* d = dir && dir[0] ? dir : ".";
    say("striso_audio %d self-test (miniaudio %s)\n", sa_api_version(), sa_miniaudio_version());
    uint32_t t0 = sa_now_us();
    test_ring();
    test_wav(d);
    test_resampler();
    test_drift();
    test_glitches();
    test_session(d);
    say("%d failure%s, %.1f s\n", g_fail, g_fail == 1 ? "" : "s", (sa_now_us() - t0) / 1e6);
    return g_fail;
}
