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
        int ok = r.underruns_late == 0 && r.resyncs == 0 && r.overruns == 0 && r.streaming && r.max_d2 < 0.01 && fabs(r.final_ppm - cases[i].ppm) < 30 + 0.1 * fabs(cases[i].ppm); /* + the margin given back meanwhile (~17 ppm) */
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

/* ---------------------------------------------------------------- realistic timing */

/* The Striso sends a USB packet every 1 ms: 47, 48 or 49 frames (its clock against the host's).
 * Windows delivers them in batches: one buffer per wake-up in exclusive mode (1..3 packets),
 * ten at once in shared mode. miniaudio may split a device buffer into several callbacks. Any
 * callback can be late (a busy system: DPCs, other drivers); the next comes on time again. */
typedef struct {
    const char* name;
    double ppm;            /* input clock vs the output's */
    int batch;             /* packets per input delivery */
    int in_split;          /* callbacks per input delivery */
    uint32_t pp;           /* output frames per wake-up */
    int out_split;         /* callbacks per output wake-up */
    double in_late_p, out_late_p;  /* chance that a delivery / wake-up is late */
    double late_min_us, late_max_us;
    double jitter_us;      /* small jitter on everything */
    double seconds, settle;
    int exclusive_out;     /* the device runs dry when a wake-up is a period late */
    uint32_t preroll;      /* frames the output takes at once when it opens (a shared WASAPI output fills
                              its whole buffer before it starts), before its periods */
} rt_cfg;

typedef struct {
    uint32_t ring_empty, ring_empty_after, glitches, glitches_after, in_late, out_late, overruns, resyncs, retargets, clamps;
    uint32_t cause_input, cause_output;
    double latency_ms, ring_ms, target_ms, margin_ms;
    double max_d2;
} rt_res;

static double urand(uint32_t* s) { return (lcg(s) % 1000000) / 1000000.0; }

static void simulate_rt(const rt_cfg* c, rt_res* r) {
    const double fs = 48000;
    sa_pass p;
    memset(r, 0, sizeof(*r));
    uint32_t in_hint = (uint32_t)(48 * c->batch);
    if (sa_pass_init(&p, fs, fs, in_hint) != 0) {
        r->ring_empty = 9999;
        return;
    }
    double period_us = c->pp / fs * 1e6;
    sa_pass_set_output(&p, c->pp, c->exclusive_out ? period_us : 0);
    uint32_t seed = 777;
    float* in = (float*)malloc(sizeof(float) * 2 * 64 * 64);
    float* out = (float*)malloc(sizeof(float) * 2 * c->pp);
    double phase = 0, dph = 2 * M_PI * 440 / fs;
    /* the input: packets every 1 ms of the input clock */
    double pkt_dt = 1e-3 / (1 + c->ppm * 1e-6);
    double t_pkt = 0.0002, sent = 0, due = 0;
    int in_batch_n = 0, in_batch_frames = 0;
    double t_out_nom = 0.0009;
    double y1 = 0, y2 = 0;
    long nout = 0;
    double lat_sum = 0, ring_sum = 0, tgt_sum = 0, mg_sum = 0;
    long lat_n = 0;
    /* pending input delivery */
    int have_delivery = 0;
    double t_delivery = 0, t_last_in = 0, t_last_out = 0;
    int delivery_frames = 0;
    if (c->preroll) {
        /* the device's own buffer filled at once, in callbacks of a period, before it plays */
        float* pre = (float*)malloc(sizeof(float) * 2 * c->pp);
        for (uint32_t done = 0; done < c->preroll; done += c->pp)
            sa_pass_pull(&p, pre, c->preroll - done < c->pp ? c->preroll - done : c->pp, (uint32_t)(t_out_nom * 1e6), 1.0f);
        free(pre);
        t_out_nom += c->pp / fs;
    }
    while (t_out_nom < c->seconds) {
        /* the next output wake-up (late or not) */
        double t_out = t_out_nom + urand(&seed) * c->jitter_us * 1e-6;
        if (urand(&seed) < c->out_late_p) t_out += (c->late_min_us + urand(&seed) * (c->late_max_us - c->late_min_us)) * 1e-6;
        if (t_out < t_last_out + 20e-6) t_out = t_last_out + 20e-6;
        t_last_out = t_out;
        /* deliver every input that arrives before it */
        for (;;) {
            if (!have_delivery) {
                /* collect the next batch of packets */
                while (in_batch_n < c->batch) {
                    due += 48;
                    int n = (int)floor(due - sent + 0.5);
                    if (urand(&seed) < 0.2 && fabs(due - sent - n) < 0.4) n += urand(&seed) < 0.5 ? -1 : 1;
                    if (n < 47) n = 47;
                    if (n > 49) n = 49;
                    sent += n;
                    in_batch_frames += n;
                    in_batch_n++;
                    t_pkt += pkt_dt;
                }
                t_delivery = t_pkt + urand(&seed) * c->jitter_us * 1e-6;
                if (urand(&seed) < c->in_late_p) t_delivery += (c->late_min_us + urand(&seed) * (c->late_max_us - c->late_min_us)) * 1e-6;
                /* a late one is followed at once by the next, never overtaken by it */
                if (t_delivery < t_last_in + 20e-6) t_delivery = t_last_in + 20e-6;
                t_last_in = t_delivery;
                delivery_frames = in_batch_frames;
                in_batch_n = 0;
                in_batch_frames = 0;
                have_delivery = 1;
            }
            if (t_delivery > t_out) break;
            int left = delivery_frames, k = 0;
            for (int s = 0; s < c->in_split; s++) {
                int part = s == c->in_split - 1 ? left : delivery_frames / c->in_split;
                for (int i = 0; i < part; i++) {
                    float v = (float)(0.5 * sin(phase));
                    in[2 * i] = v;
                    in[2 * i + 1] = -v;
                    phase += dph;
                    if (phase > 2 * M_PI) phase -= 2 * M_PI;
                }
                sa_pass_push(&p, in, (uint32_t)part, (uint32_t)((t_delivery + k * 5e-6) * 1e6));
                left -= part;
                k++;
            }
            have_delivery = 0;
        }
        /* the output wake-up, in out_split callbacks */
        uint32_t e0 = sa_ld(&p.underruns), g0 = sa_ld(&p.out_glitches);
        for (int s = 0; s < c->out_split; s++) {
            uint32_t part = c->pp / c->out_split;
            if (s == c->out_split - 1) part = c->pp - part * (c->out_split - 1);
            sa_pass_pull(&p, out, part, (uint32_t)((t_out + s * 5e-6) * 1e6), 1.0f);
            for (uint32_t i = 0; i < part; i++) {
                double y = out[2 * i];
                if (nout >= 2) {
                    double d2 = fabs(y - 2 * y1 + y2);
                    if (d2 > r->max_d2) r->max_d2 = d2;
                }
                y2 = y1;
                y1 = y;
                nout++;
            }
        }
        if (t_out_nom > c->settle) {
            r->ring_empty_after += sa_ld(&p.underruns) - e0;
            r->glitches_after += sa_ld(&p.out_glitches) - g0;
            double ring = sa_ldf(&p.st_ring) / fs * 1000;
            double nom = sa_ld(&p.tin.st_nominal_us) * 1e-3;
            /* as the app shows it: the wait for the input's next delivery (half its interval),
               the ring, the output's buffer */
            lat_sum += nom / 2 + ring + c->pp / fs * 1000;
            ring_sum += ring;
            tgt_sum += sa_ldf(&p.st_target) / fs * 1000;
            mg_sum += sa_ldf(&p.st_margin) / fs * 1000;
            lat_n++;
        }
        t_out_nom += c->pp / fs;
    }
    /* the causes the events give */
    sa_evq_item it;
    while (sa_evq_pop(&p.ev_out, &it))
        if (it.type == SA_EV_RING_EMPTY) {
            if (it.c) r->cause_input++;
            else r->cause_output++;
        }
    while (sa_evq_pop(&p.ev_in, &it)) {
    }
    r->ring_empty = sa_ld(&p.underruns);
    r->glitches = sa_ld(&p.out_glitches);
    r->in_late = sa_ld(&p.in_late);
    r->out_late = sa_ld(&p.out_late);
    r->overruns = sa_ld(&p.overruns);
    r->resyncs = sa_ld(&p.resyncs);
    r->retargets = sa_ld(&p.retargets);
    r->clamps = sa_ld(&p.clamps);
    r->latency_ms = lat_n ? lat_sum / lat_n : 0;
    r->ring_ms = lat_n ? ring_sum / lat_n : 0;
    r->target_ms = lat_n ? tgt_sum / lat_n : 0;
    r->margin_ms = lat_n ? mg_sum / lat_n : 0;
    free(in);
    free(out);
    sa_pass_free(&p);
}

/* What miniaudio did before (three callbacks per device buffer on both sides) and what Windows'
 * shared-mode input does (ten packets at once): the target follows the bursts, not the callbacks. */
static void test_bursts(void) {
    rt_cfg cases[] = {
        /* name, ppm, batch, in_split, pp, out_split, in_late_p, out_late_p, late min, max, jitter, s, settle, excl */
        {"exclusive 4 ms buffers in 3 callbacks each side (the old 64-frame setting)", 40, 4, 3, 192, 3, 0, 0, 0, 0, 150, 30, 3, 1},
        {"shared input: 10 x 1 ms packets every 10 ms, 128-frame output", -60, 10, 1, 128, 1, 0, 0, 0, 0, 400, 30, 3, 1},
        {"shared input in 3 callbacks per batch, 64-frame output", 120, 10, 3, 64, 1, 0, 0, 0, 0, 400, 30, 3, 1},
        {"1 ms packets one by one (UAC 1 ms periods), 48-frame output", -25, 1, 1, 48, 1, 0, 0, 0, 0, 100, 30, 3, 1},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        rt_res r;
        simulate_rt(&cases[i], &r);
        char what[400];
        snprintf(what, sizeof(what), "bursts, %s: %u ring-empty (%u after %.0f s), %u overruns, %u resyncs; latency %.2f ms (ring %.2f, target %.2f, margin %.2f), max step %.4f",
                 cases[i].name, r.ring_empty, r.ring_empty_after, cases[i].settle, r.overruns, r.resyncs, r.latency_ms, r.ring_ms, r.target_ms, r.margin_ms, r.max_d2);
        check(r.ring_empty == 0 && r.overruns == 0 && r.resyncs == 0 && r.max_d2 < 0.01, what);
    }
}

/* The start of a shared output (2026-10-26 on the user's machine, every launch: the servo at its
 * limit for about 8 s, then a dropout): WASAPI's shared mode fills the device's whole buffer (three
 * periods) in one burst before it plays. That burst must not size the ring: it only fills the
 * device, and the ring's target planned for it falls after the start, leaving the servo to drain
 * the difference at its limit (and overshoot). The exclusive input of the Striso (3 ms, 144 frames). */
static void test_preroll(void) {
    rt_cfg cases[] = {
        /* name, ppm, batch, in_split, pp, out_split, in_late_p, out_late_p, late min, max, jitter, s, settle, excl, preroll */
        {"shared output, 480-frame periods, its 1440-frame buffer filled at the start", 40, 3, 1, 480, 1, 0, 0, 0, 0, 150, 30, 0, 0, 1440},
        {"shared output, 480-frame periods, no pre-roll", 40, 3, 1, 480, 1, 0, 0, 0, 0, 150, 30, 0, 0, 0},
        {"exclusive output, 144-frame periods, one period filled at the start", -30, 3, 1, 144, 1, 0, 0, 0, 0, 150, 30, 0, 1, 144},
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        rt_res r;
        simulate_rt(&cases[i], &r);
        char what[400];
        snprintf(what, sizeof(what), "start, %s: %u servo-limit reports, %u ring-empty, %u resyncs, %u retargets; target %.2f ms, latency %.2f ms",
                 cases[i].name, r.clamps, r.ring_empty, r.resyncs, r.retargets, r.target_ms, r.latency_ms);
        check(r.clamps == 0 && r.ring_empty == 0 && r.resyncs == 0, what);
    }
}

/* Late callbacks: the counters see them, the ring target absorbs late input, and late output
 * beyond one period is counted as the device's dropout (exclusive mode cannot bridge it). */
static void test_late(void) {
    rt_cfg c = {"late input", 30, 1, 1, 64, 1, 0.01, 0, 1000, 3000, 100, 40, 5, 1};
    rt_res r;
    simulate_rt(&c, &r);
    char what[400];
    snprintf(what, sizeof(what), "late input (1%% of 1 ms deliveries 1-3 ms late): %u counted late, %u ring-empty (%u after %.0f s; cause input %u, output %u), latency %.2f ms (target %.2f)",
             r.in_late, r.ring_empty, r.ring_empty_after, c.settle, r.cause_input, r.cause_output, r.latency_ms, r.target_ms);
    check(r.in_late > 100 && r.ring_empty_after == 0 && r.ring_empty <= 3 && r.cause_output == 0 && r.max_d2 < 0.01, what);

    rt_cfg o = {"late output", -30, 1, 1, 64, 1, 0, 0.01, 1000, 3000, 100, 40, 5, 1};
    simulate_rt(&o, &r);
    snprintf(what, sizeof(what), "late output (1%% of 1.33 ms wake-ups 1-3 ms late, exclusive): %u counted late, %u beyond one period (device dropouts), %u ring-empty after settling",
             r.out_late, r.glitches, r.ring_empty_after);
    check(r.out_late > 100 && r.glitches > 50 && r.glitches <= r.out_late && r.ring_empty_after == 0, what);
}

/* The buffer sweep Auto walks: input in 1 ms packets (exclusive) or 10 ms batches (shared), the
 * output at 64..512 frames, both sides with late wake-ups. The smallest setting without a dropout
 * is what Auto settles on; its latency is the best this system allows. */
/* This PC's USB devices (the Striso, the TBT200 dock's DAC) report a 144-frame (3 ms) minimum
 * exclusive period: the input comes as 3 ms buffers, the output wakes every 3 ms (Auto's 64 and
 * 128 both open at 144). The latency through the computer at that minimum, quiet and busy. */
static void test_device_min(void) {
    struct {
        const char* name;
        double late_p, late_max;
        uint32_t pp;
        int must_be_clean;
    } c[] = {
        {"3 ms periods both sides, quiet system", 0.005, 1000, 144, 1},
        {"3 ms periods both sides, 0.5% wake-ups 1-3 ms late", 0.005, 3000, 144, 0},
        {"3 ms in, 256-frame out, 0.5% wake-ups 1-3 ms late", 0.005, 3000, 256, 1},
    };
    for (size_t i = 0; i < sizeof(c) / sizeof(c[0]); i++) {
        rt_cfg k = {"min", 50, 3, 1, c[i].pp, 1, c[i].late_p, c[i].late_p, 1000, c[i].late_max, 150, 60, 2, 1};
        rt_res r;
        simulate_rt(&k, &r);
        char what[400];
        snprintf(what, sizeof(what), "device minimum, %s: %u dropouts after settling (%u ring-empty, %u output late beyond a period), %.2f ms through the computer (ring %.2f, target %.2f)",
                 c[i].name, r.ring_empty_after + r.glitches_after, r.ring_empty_after, r.glitches_after, r.latency_ms, r.ring_ms, r.target_ms);
        check(!c[i].must_be_clean || r.ring_empty_after + r.glitches_after == 0, what);
    }
}

static void test_sweep(void) {
    struct {
        const char* name;
        int batch;
        double late_p, late_max;
    } env[] = {
        {"exclusive input (1 ms), 0.5% of wake-ups 1-3 ms late", 1, 0.005, 3000},
        {"exclusive input (3 ms buffers), 0.5% 1-3 ms late", 3, 0.005, 3000},
        {"shared input (10 x 1 ms every 10 ms), 0.5% 1-3 ms late", 10, 0.005, 3000},
        {"exclusive input (1 ms), quiet system (0.5% up to 1 ms late)", 1, 0.005, 1000},
    };
    const uint32_t sizes[] = {64, 128, 256, 512};
    for (size_t e = 0; e < sizeof(env) / sizeof(env[0]); e++) {
        int chosen = -1;
        double lat[4] = {0};
        uint32_t drops[4] = {0};
        for (int k = 0; k < 4; k++) {
            rt_cfg c = {"sweep", 50, env[e].batch, 1, sizes[k], 1, env[e].late_p, env[e].late_p, 1000, env[e].late_max, 150, 60, 2, 1};
            rt_res r;
            simulate_rt(&c, &r);
            drops[k] = r.ring_empty_after + r.glitches_after;
            lat[k] = r.latency_ms;
            if (chosen < 0 && drops[k] == 0) chosen = k;
        }
        char what[400];
        snprintf(what, sizeof(what), "sweep, %s: dropouts 64:%u 128:%u 256:%u 512:%u -> Auto %u frames, %.2f ms through the computer (64: %.2f, 128: %.2f, 256: %.2f)",
                 env[e].name, drops[0], drops[1], drops[2], drops[3], chosen >= 0 ? sizes[chosen] : 0, chosen >= 0 ? lat[chosen] : 0.0, lat[0], lat[1], lat[2]);
        /* a setting without dropouts exists, and every larger one is clean too (Auto never needs to
           go past it) */
        int ok = chosen >= 0;
        for (int k = chosen; ok && k < 4; k++) ok = drops[k] == 0;
        check(ok, what);
    }
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
static int rec_refused(const sa_status* s) { return s->record_state == SA_REC_STOPPED && s->record_error == SA_ERR_NOT_RUNNING; }

static void test_session(const char* dir) {
    if (sa_internal_inited()) {
        check(0, "session: the library is in use (sa_init was called): skipped");
        return;
    }
    sa_status s;
    check(sa_sizeof_status() == (int32_t)sizeof(sa_status) && sizeof(sa_status) % 4 == 0 && sizeof(sa_device) == 512 + 8 * 4 && sa_sizeof_event() == (int32_t)sizeof(sa_event) && sizeof(sa_event) == 32, "struct sizes");
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
    /* (the engine thread answers it: up to 2 s on a busy machine, a CI runner took over 80 ms) */
    check(wait_for(rec_refused, 2000, &s), "session: recording without the input is refused");
    sa_shutdown();
    sa_get_status(&s);
    check(s.initialised == 0, "session: shutdown");
}

/* the event log and the counters on the null backend, with late callbacks injected */
static int has_event(const sa_event* ev, int n, int32_t type, int32_t a) {
    for (int i = 0; i < n; i++)
        if (ev[i].type == type && (a < 0 || ev[i].a == a)) return 1;
    return 0;
}

static void test_session_jitter(void) {
    if (sa_internal_inited()) {
        check(0, "jitter session: the library is in use: skipped");
        return;
    }
    sa_status s;
    if (sa_init(SA_BACKEND_NULL) != SA_OK) {
        check(0, "jitter session: null backend init");
        return;
    }
    sa_timer_1ms(1); /* the injected sleeps of 1-3 ms need a 1 ms timer */
    sa_get_status(&s);
    g_dev_gen = s.devices_gen;
    sa_enumerate();
    wait_for(enumerated, 2000, &s);
    sa_device cap;
    memset(&cap, 0, sizeof(cap));
    if (sa_device_get(1, 0, &cap) != SA_OK) {
        check(0, "jitter session: no input");
        sa_shutdown();
        return;
    }
    g_gen = sa_configure(1, cap.name, "", 256, 1, 0);
    int ok = wait_for(both_running, 3000, &s) && wait_for(streaming, 3000, &s);
    static sa_event ev[512];
    int n = sa_get_events(0, ev, 512);
    int ordered = 1;
    for (int i = 1; i < n; i++) {
        uint64_t a = ((uint64_t)ev[i - 1].t_hi << 32) | ev[i - 1].t_lo, b = ((uint64_t)ev[i].t_hi << 32) | ev[i].t_lo;
        if (ev[i].seq != ev[i - 1].seq + 1 || b < a) ordered = 0;
    }
    char what[600];
    snprintf(what, sizeof(what), "events: %d logged (input and output opened, streaming started), numbered and in time order, ids \"%s\"", n, cap.id);
    check(ok && n >= 3 && has_event(ev, n, SA_EV_OPEN, 1) && has_event(ev, n, SA_EV_OPEN, 0) && has_event(ev, n, SA_EV_STREAM, -1) && ordered && cap.id[0], what);
    uint32_t seq = s.event_seq;

    /* every 20th input callback 1-16 ms late (the null backend wakes every 10 ms) */
    sa_test_jitter(16000, 20, 0);
    sa_sleep_ms(2500);
    sa_test_jitter(0, 0, 0);
    sa_sleep_ms(100);
    sa_get_status(&s);
    n = sa_get_events(seq, ev, 512);
    snprintf(what, sizeof(what), "late input counted: %u late, %u ring-empty, input every %.2f ms (max %.2f ms), ring target %.1f ms", s.in_late, s.underruns,
             s.cap_nominal_us / 1000.0, s.cap_max_gap_us / 1000.0, s.target_ms);
    check(s.in_late > 0 && has_event(ev, n, SA_EV_IN_LATE, -1) && s.cap_max_gap_us > s.cap_nominal_us + 5000 && s.underruns <= 3, what);

    /* every 20th output callback 1-16 ms late: beyond one period, a dropout */
    g_gen = sa_configure(1, cap.name, "", 64, 1, 0);
    wait_for(both_running, 3000, &s);
    wait_for(streaming, 3000, &s);
    seq = s.event_seq;
    sa_test_jitter(16000, 20, 1);
    sa_sleep_ms(2500);
    sa_test_jitter(0, 0, 0);
    sa_sleep_ms(100);
    sa_get_status(&s);
    n = sa_get_events(seq, ev, 512);
    snprintf(what, sizeof(what), "late output counted: %u late, %u beyond a period, output every %.2f ms (max %.2f ms), latency %.1f ms (in %.1f, ring %.1f, out %.1f)",
             s.out_late, s.out_glitches, s.play_nominal_us / 1000.0, s.play_max_gap_us / 1000.0, s.latency_ms, s.in_ms, s.ring_ms, s.out_ms);
    check(s.out_late > 0 && s.out_glitches > 0 && has_event(ev, n, SA_EV_OUT_LATE, -1) && s.latency_ms > 0 && fabsf(s.latency_ms - (s.in_ms + s.ring_ms + s.out_ms)) < 0.01f, what);
    g_gen = sa_configure(0, "", "", 64, 0, 0);
    wait_for(applied, 2000, &s);
    sa_timer_1ms(0);
    sa_shutdown();
}

/* sa_set_source on the null backend's output: a detach (or a swap) returns only when the output
 * callback is no longer inside the previous source */
static volatile uint32_t g_src_calls, g_src_inside, g_src_badpair, g_src2_calls;
static int32_t count_src(void* user, float* stereo, int32_t frames, int32_t rate) {
    (void)rate;
    sa_st(&g_src_inside, 1);
    if (user != (void*)&g_src_calls) sa_inc(&g_src_badpair);
    sa_sleep_ms(2); /* a source that takes a while: the detach has something to wait for */
    memset(stereo, 0, sizeof(float) * 2 * (size_t)frames);
    sa_inc(&g_src_calls);
    sa_st(&g_src_inside, 0);
    return frames;
}
static int32_t count_src2(void* user, float* stereo, int32_t frames, int32_t rate) {
    (void)rate;
    if (user != (void*)&g_src2_calls) sa_inc(&g_src_badpair);
    memset(stereo, 0, sizeof(float) * 2 * (size_t)frames);
    sa_inc(&g_src2_calls);
    return frames;
}
static int play_running(const sa_status* s) { return applied(s) && s->playback_state == SA_DEV_RUNNING; }

static void test_source_guard(void) {
    if (sa_internal_inited()) {
        check(0, "source guard: the library is in use: skipped");
        return;
    }
    sa_status s;
    if (sa_init(SA_BACKEND_NULL) != SA_OK) {
        check(0, "source guard: null backend init");
        return;
    }
    sa_get_status(&s);
    g_dev_gen = s.devices_gen;
    sa_enumerate();
    wait_for(enumerated, 2000, &s);
    g_gen = sa_configure(1, "", "", 256, 0, SA_OUTPUT_ONLY);
    int ok = wait_for(play_running, 3000, &s);
    sa_st(&g_src_calls, 0);
    sa_st(&g_src2_calls, 0);
    sa_st(&g_src_badpair, 0);
    int bad = 0, rounds = 0, busy = 0;
    for (int r = 0; ok && r < 15; r++) {
        busy += sa_set_source(count_src, (void*)&g_src_calls) != SA_OK;
        const uint32_t c0 = sa_ld(&g_src_calls);
        for (int t = 0; t < 200 && sa_ld(&g_src_calls) < c0 + 2; t++) sa_sleep_ms(1);
        busy += sa_set_source(NULL, NULL) != SA_OK;
        const uint32_t inside = sa_ld(&g_src_inside), c = sa_ld(&g_src_calls);
        sa_sleep_ms(15);
        if (inside || sa_ld(&g_src_calls) != c) bad++;
        rounds++;
    }
    char what[300];
    snprintf(what, sizeof(what), "source guard: %d detaches while the output plays (%u calls): none inside or after a detach returned", rounds,
             sa_ld(&g_src_calls));
    check(ok && rounds == 15 && bad == 0 && busy == 0 && sa_ld(&g_src_calls) >= 30, what);

    /* a swap from one source to another: the first is done when it returns, the second has its own user */
    sa_set_source(count_src, (void*)&g_src_calls);
    sa_sleep_ms(30);
    const int32_t r = sa_set_source(count_src2, (void*)&g_src2_calls);
    const uint32_t inside = sa_ld(&g_src_inside), c = sa_ld(&g_src_calls);
    sa_sleep_ms(40);
    check(r == SA_OK && !inside && sa_ld(&g_src_calls) == c && sa_ld(&g_src2_calls) > 2 && sa_ld(&g_src_badpair) == 0,
          "source guard: a swap leaves the previous source at once; each source gets its own user");
    sa_set_source(NULL, NULL);
    g_gen = sa_configure(0, "", "", 256, 0, 0);
    wait_for(applied, 2000, &s);
    sa_shutdown();
}

void sa_selftest_midi(void (*say)(const char* fmt, ...), void (*check)(int ok, const char* what));

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
    test_bursts();
    test_preroll();
    test_late();
    test_sweep();
    test_device_min();
    test_session(d);
    test_session_jitter();
    test_source_guard();
    sa_selftest_midi(say, check);
    say("%d failure%s, %.1f s\n", g_fail, g_fail == 1 ? "" : "s", (sa_now_us() - t0) / 1e6);
    return g_fail;
}
