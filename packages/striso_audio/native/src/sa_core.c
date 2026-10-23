/* The audio math of striso_audio: see sa_core.h. */
#include "sa_core.h"
#include "striso_audio.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ---------------------------------------------------------------- ring */

int sa_ring_init(sa_ring* rb, uint32_t min_frames) {
    uint32_t cap = 64;
    while (cap < min_frames) cap <<= 1;
    rb->buf = (float*)calloc((size_t)cap * 2, sizeof(float));
    rb->cap = cap;
    rb->w = 0;
    rb->r = 0;
    return rb->buf ? 0 : -1;
}

void sa_ring_free(sa_ring* rb) {
    free(rb->buf);
    rb->buf = NULL;
    rb->cap = 0;
}

uint32_t sa_ring_fill(sa_ring* rb) { return sa_ld(&rb->w) - sa_ld(&rb->r); }

uint32_t sa_ring_write(sa_ring* rb, const float* src, uint32_t frames) {
    uint32_t w = rb->w, r = sa_ld(&rb->r);
    uint32_t room = rb->cap - (w - r);
    uint32_t n = frames < room ? frames : room;
    uint32_t idx = w & (rb->cap - 1);
    uint32_t first = n < rb->cap - idx ? n : rb->cap - idx;
    memcpy(rb->buf + (size_t)idx * 2, src, (size_t)first * 2 * sizeof(float));
    if (n > first) memcpy(rb->buf, src + (size_t)first * 2, (size_t)(n - first) * 2 * sizeof(float));
    sa_st(&rb->w, w + n);
    return n;
}

uint32_t sa_ring_read(sa_ring* rb, float* dst, uint32_t frames) {
    uint32_t r = rb->r, w = sa_ld(&rb->w);
    uint32_t fill = w - r;
    uint32_t n = frames < fill ? frames : fill;
    uint32_t idx = r & (rb->cap - 1);
    uint32_t first = n < rb->cap - idx ? n : rb->cap - idx;
    memcpy(dst, rb->buf + (size_t)idx * 2, (size_t)first * 2 * sizeof(float));
    if (n > first) memcpy(dst + (size_t)first * 2, rb->buf, (size_t)(n - first) * 2 * sizeof(float));
    sa_st(&rb->r, r + n);
    return n;
}

void sa_ring_skip(sa_ring* rb, uint32_t frames) {
    uint32_t r = rb->r, w = sa_ld(&rb->w);
    uint32_t fill = w - r;
    sa_st(&rb->r, r + (frames < fill ? frames : fill));
}

/* ---------------------------------------------------------------- resampler kernels */

static double bessel_i0(double x) {
    double sum = 1, term = 1, q = x * x / 4;
    for (int k = 1; k < 60; k++) {
        term *= q / ((double)k * k);
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

void sa_sinc_table(float* table, double cutoff, double beta) {
    double i0b = bessel_i0(beta);
    double h[SA_TAPS];
    for (int ph = 0; ph <= SA_PHASES; ph++) {
        double frac = (double)ph / SA_PHASES, sum = 0;
        for (int k = 0; k < SA_TAPS; k++) {
            /* distance from the output position to input sample k of the window */
            double u = frac + (SA_HALF - 1) - k;
            double z = cutoff * u;
            double s = fabs(z) < 1e-12 ? 1.0 : sin(M_PI * z) / (M_PI * z);
            double q = u / SA_HALF;
            double win = q * q >= 1 ? 0.0 : bessel_i0(beta * sqrt(1 - q * q)) / i0b;
            h[k] = cutoff * s * win;
            sum += h[k];
        }
        for (int k = 0; k < SA_TAPS; k++) table[ph * SA_TAPS + k] = (float)(h[k] / sum);
    }
}

/* ---------------------------------------------------------------- timing */

void sa_wmax_put(sa_wmax* w, float v, uint32_t now) {
    if (!w->started) {
        memset(w->b, 0, sizeof(w->b));
        w->i = 0;
        w->t0 = now;
        w->started = 1;
    }
    for (int rot = 0; (uint32_t)(now - w->t0) >= SA_WBUCKET_US; rot++) {
        if (rot >= SA_WBUCKETS) { /* a long pause: everything is old */
            memset(w->b, 0, sizeof(w->b));
            w->t0 = now;
            break;
        }
        w->i = (w->i + 1) % SA_WBUCKETS;
        w->b[w->i] = 0;
        w->t0 += SA_WBUCKET_US;
    }
    if (v > w->b[w->i]) w->b[w->i] = v;
}

float sa_wmax_get(const sa_wmax* w) {
    float m = 0;
    for (int i = 0; i < SA_WBUCKETS; i++)
        if (w->b[i] > m) m = w->b[i];
    return m;
}

uint32_t sa_timing_cb(sa_timing* t, uint32_t frames, uint32_t now) {
    if (!t->have) {
        t->have = 1;
        t->start_us = t->end_us = now;
        t->frames = frames;
        return 0;
    }
    if ((uint32_t)(now - t->end_us) <= SA_BURST_US) {
        t->frames += frames;
        t->end_us = now;
        if (t->frames > sa_ld(&t->st_burst_max)) sa_st(&t->st_burst_max, t->frames);
        return 0;
    }
    /* the burst before is complete; this callback starts the next */
    uint32_t gap = now - t->start_us;
    if (gap == 0) gap = 1;
    float fb = (float)t->frames;
    t->burst_s = t->bursts ? t->burst_s + 0.05 * (fb - t->burst_s) : fb;
    sa_wmax_put(&t->burst_w, fb, now);
    if (t->bursts < 8) {
        /* the first intervals after opening: the smallest is the best guess of the period */
        t->nominal_us = (t->nominal_us <= 0 || gap < t->nominal_us) ? gap : t->nominal_us + 0.2 * (gap - t->nominal_us);
    } else if (gap < 1.5 * t->nominal_us) {
        t->nominal_us += 0.05 * (gap - t->nominal_us);
    } else {
        t->nominal_us += 0.002 * (gap - t->nominal_us); /* late ones barely move it */
    }
    t->bursts++;
    if (t->bursts > 2) { /* not the start-up's */
        if (gap > t->max_gap_us) t->max_gap_us = gap;
        sa_wmax_put(&t->gap_w, (float)gap, now);
    }
    t->last_gap_us = gap;
    t->start_us = t->end_us = now;
    t->frames = frames;
    sa_st(&t->st_nominal_us, (uint32_t)(t->nominal_us + 0.5));
    sa_st(&t->st_max_gap_us, t->max_gap_us);
    sa_st(&t->st_recent_gap_us, (uint32_t)sa_wmax_get(&t->gap_w));
    sa_st(&t->st_burst, (uint32_t)(t->burst_s + 0.5));
    float bm = sa_wmax_get(&t->burst_w);
    sa_st(&t->st_burst_max, (uint32_t)(bm > frames ? bm : frames));
    return gap;
}

/* ---------------------------------------------------------------- events */

void sa_evq_push(sa_evq* q, int32_t type, uint32_t t_us, int32_t a, int32_t b, int32_t c) {
    uint32_t w = q->w, r = sa_ld(&q->r);
    if (w - r >= SA_EVQ) {
        sa_inc(&q->lost);
        return;
    }
    sa_evq_item* it = &q->it[w & (SA_EVQ - 1)];
    it->type = type;
    it->t_us = t_us;
    it->a = a;
    it->b = b;
    it->c = c;
    sa_st(&q->w, w + 1);
}

int sa_evq_pop(sa_evq* q, sa_evq_item* out) {
    uint32_t r = q->r, w = sa_ld(&q->w);
    if (r == w) return 0;
    *out = q->it[r & (SA_EVQ - 1)];
    sa_st(&q->r, r + 1);
    return 1;
}

/* ---------------------------------------------------------------- passthrough */

#define SA_KP 0.5            /* ratio correction per second of fill error */
#define SA_KI 0.08           /* per second^2 */
#define SA_MAXCORR 0.004     /* +-4000 ppm at most (7 cents; real clocks differ by < 200 ppm) */
#define SA_FILL_TAU 0.2      /* s, smoothing of the virtual fill */
#define SA_FADE_IN_S 0.005
#define SA_FADE_OUT_S 0.002
#define SA_SAFETY_S 0.0005   /* on top of the measured need: the servo's own wobble */
#define SA_HYST_S 0.00025    /* the target only moves down by more than this */
#define SA_CALM_US 15000000u /* the margin shrinks after this long without an underrun */
#define SA_START_MARGIN_S 0.001 /* the margin to start with (the servo finds the drift meanwhile) */

static void rs_reset(sa_pass* p) {
    memset(p->x, 0, (size_t)SA_HALF * 2 * sizeof(float));
    p->have = SA_HALF;
    p->pos = SA_HALF - 1;
}

int sa_pass_init(sa_pass* p, double fs_in, double fs_out, uint32_t in_hint) {
    memset(p, 0, sizeof(*p));
    if (fs_in <= 0 || fs_out <= 0) return -1;
    if (sa_ring_init(&p->ring, 16384) != 0) return -1;
    p->fs_in = fs_in;
    p->fs_out = fs_out;
    p->ratio_nom = fs_in / fs_out;
    if (p->ratio_nom > SA_MAXRATIO / 1.01) p->ratio_nom = SA_MAXRATIO / 1.01;
    p->table = (float*)malloc(sizeof(float) * (SA_PHASES + 1) * SA_TAPS);
    p->x = (float*)calloc((size_t)SA_HIST * 2, sizeof(float));
    if (!p->table || !p->x) {
        sa_pass_free(p);
        return -1;
    }
    /* below the output's Nyquist when going down in rate */
    sa_sinc_table(p->table, 0.94 * (p->ratio_nom > 1 ? 1 / p->ratio_nom : 1.0), 7.0);
    rs_reset(p);
    p->last_block = in_hint;
    p->in_hint = in_hint > 0 ? in_hint : 128;
    p->gain_s = -1; /* first pull takes the gain as it is */
    p->min_slack = 1e9;
    /* start with room for the servo to find the clocks' drift; stable playing gives it back */
    p->margin = SA_START_MARGIN_S * fs_in;
    return 0;
}

void sa_pass_set_output(sa_pass* p, uint32_t out_hint, double out_slack_us) {
    p->out_hint = out_hint;
    p->out_slack_us = out_slack_us;
}

void sa_pass_free(sa_pass* p) {
    sa_ring_free(&p->ring);
    free(p->table);
    free(p->x);
    p->table = NULL;
    p->x = NULL;
}

void sa_pass_push(sa_pass* p, const float* in, uint32_t frames, uint32_t now_us) {
    uint32_t gap = sa_timing_cb(&p->tin, frames, now_us);
    if (gap) {
        sa_st(&p->last_in_gap_us, gap);
        double nom = p->tin.nominal_us;
        if (nom > 0 && p->tin.bursts > 4 && gap > 1.5 * nom + 500) {
            sa_inc(&p->in_late);
            sa_evq_push(&p->ev_in, SA_EV_IN_LATE, now_us, (int32_t)gap, (int32_t)nom, (int32_t)sa_ring_fill(&p->ring));
        }
    }
    /* what the output side plans for: the longest wait for the input, its biggest burst */
    double wait = sa_wmax_get(&p->tin.gap_w) * 1e-6 * p->fs_in;
    double burst = sa_wmax_get(&p->tin.burst_w);
    if (p->tin.frames > burst) burst = p->tin.frames;
    sa_stf(&p->st_in_gap, (float)wait);
    sa_stf(&p->st_in_burst, (float)burst);

    uint32_t n = sa_ring_write(&p->ring, in, frames);
    if (n < frames) {
        sa_inc(&p->overruns);
        sa_evq_push(&p->ev_in, SA_EV_IN_OVERRUN, now_us, (int32_t)(frames - n), (int32_t)sa_ring_fill(&p->ring), 0);
    }
    sa_st(&p->last_block, frames);
    sa_st(&p->stamp_us, now_us);
    sa_inc(&p->pushes);
}

static void pull_block(sa_pass* p, float* out, uint32_t n, uint32_t now_us, float gain, double out_burst) {
    const double fs_in = p->fs_in, fs_out = p->fs_out;
    /* a consistent (stamp, fill) pair */
    uint32_t s1 = sa_ld(&p->stamp_us), fill = sa_ring_fill(&p->ring);
    uint32_t s2 = sa_ld(&p->stamp_us);
    if (s1 != s2) {
        fill = sa_ring_fill(&p->ring);
        s1 = s2;
    }
    /* the input: the longest wait and the biggest burst it showed (at least what its device said) */
    double wait = sa_ldf(&p->st_in_gap), in_burst = sa_ldf(&p->st_in_burst);
    if (wait < p->in_hint) wait = p->in_hint;
    if (in_burst < 1) in_burst = p->in_hint;
    /* frames the input has produced since its last block (at most one longest wait) */
    double el = 0;
    if (sa_ld(&p->pushes) > 0) {
        el = (double)(int32_t)(now_us - s1) * 1e-6 * fs_in;
        if (el < 0) el = 0;
        if (el > wait) el = wait;
    }
    double backlog = (double)p->have - p->pos;
    double fv = fill + backlog + el;
    const double safety = SA_SAFETY_S * fs_in, hyst = SA_HYST_S * fs_in;
    /* what the ring must hold: the longest wait for the input + the output's biggest take + the
       resampler's look-ahead + safety + the margin earned by underruns */
    double computed = wait + out_burst * p->ratio_nom + SA_HALF + 2 + safety + p->margin;
    /* hysteresis: up at once, down only by more than hyst */
    if (computed > p->target_used || computed < p->target_used - hyst) p->target_used = computed;
    double target = p->target_used;
    if (p->started && fabs(target - p->target) >= 24 * fs_in / 48000) {
        sa_inc(&p->retargets);
        sa_evq_push(&p->ev_out, SA_EV_TARGET, now_us, (int32_t)target, (int32_t)p->target, target < p->target ? 1 : 0);
        p->target = target;
    } else if (!p->started) {
        p->target = target;
    }
    p->out_period = n;
    double dt = n / fs_out;

    if (!p->running) {
        double need0 = ceil((n - 1) * p->ratio_nom) + SA_HALF + 2;
        /* only once the input's timing is known (a few bursts): the target plans for its interval */
        int timed = p->fixed_ratio > 0 || *(volatile uint32_t*)&p->tin.bursts >= 4;
        if (fv >= target && fill >= need0 && timed) {
            /* begin at the target: what came in while waiting would only wind up the servo
               (silence so far, nothing is heard of the cut) */
            double extra = fv - target;
            if (extra > fill - need0) extra = fill - need0;
            if (extra >= 1) {
                sa_ring_skip(&p->ring, (uint32_t)extra);
                fill = sa_ring_fill(&p->ring);
                fv = fill + backlog + el;
            }
            rs_reset(p);
            p->stream_us = now_us;
            p->running = 1;
            p->fade = 0;
            if (!p->started) {
                p->fill_s = fv;
                p->integ = 0;
                p->ring_s = fill + SA_HALF;
            }
            p->calm_t0 = now_us;
            p->min_slack = 1e9;
            p->started = 1;
            p->target = target;
            sa_evq_push(&p->ev_out, SA_EV_STREAM, now_us, (int32_t)target, (int32_t)p->margin, 0);
            /* the history was reset: the backlog changed */
            backlog = (double)p->have - p->pos;
        } else {
            memset(out, 0, (size_t)n * 2 * sizeof(float));
            p->peak *= (float)exp(-dt / 0.3);
            sa_stf(&p->st_peak, p->peak);
            sa_st(&p->streaming, 0);
            sa_stf(&p->st_target, (float)target);
            sa_stf(&p->st_margin, (float)p->margin);
            return;
        }
    }

    /* the servo: hold the smoothed virtual fill at the target */
    double a = 1 - exp(-dt / SA_FILL_TAU);
    p->fill_s += a * (fv - p->fill_s);
    double e = (p->fill_s - target) / fs_in; /* seconds */
    p->integ += e * dt;
    double ilim = SA_MAXCORR / SA_KI;
    if (p->integ > ilim) p->integ = ilim;
    if (p->integ < -ilim) p->integ = -ilim;
    double corr = SA_KP * e + SA_KI * p->integ;
    int at_limit = 0;
    if (corr > SA_MAXCORR) {
        corr = SA_MAXCORR;
        at_limit = 1;
    }
    if (corr < -SA_MAXCORR) {
        corr = -SA_MAXCORR;
        at_limit = 1;
    }
    /* (right after priming the fill overshoots by up to an input burst: not worth a word) */
    if (at_limit && p->fixed_ratio <= 0 && (uint32_t)(now_us - p->stream_us) > 1000000u) {
        if (!p->clamped || (uint32_t)(now_us - p->clamp_us) > 1000000u) {
            sa_inc(&p->clamps);
            sa_evq_push(&p->ev_out, SA_EV_SERVO_LIMIT, now_us, (int32_t)(corr * 1e6), (int32_t)(fv - target), 0);
            p->clamp_us = now_us;
        }
        p->clamped = 1;
    } else {
        p->clamped = 0;
    }
    double r = p->fixed_ratio > 0 ? p->fixed_ratio : p->ratio_nom * (1 + corr);

    /* after a stall the ring may hold far too much: cut back (faded) */
    double too_full = target + (4.0 * in_burst > 2048 + n ? 4.0 * in_burst : 2048.0 + n);
    int resync = fv > too_full;

    /* bring in the input this block needs */
    uint32_t need_have = (uint32_t)floor(p->pos + (n - 1) * r) + SA_HALF + 1;
    /* how much was to spare (for tightening the margin) */
    double slack = fill + (double)p->have - need_have;
    if (slack < p->min_slack) p->min_slack = slack;
    /* the ring's real delay, for the latency: what waits beyond the read point, mid-take */
    p->ring_s += a * ((fill + backlog - 0.5 * n * r) - p->ring_s);

    uint32_t deficit = 0, stop_at = n;
    double dr = 0; /* rate change per output frame (only while running dry) */
    int underrun = 0;
    uint32_t fade_in = (uint32_t)(SA_FADE_IN_S * fs_out), fade_out = (uint32_t)(SA_FADE_OUT_S * fs_out);
    if (fade_in < 1) fade_in = 1;
    if (fade_out < 1) fade_out = 1;
    uint32_t need = need_have > p->have ? need_have - p->have : 0;
    if (need > 0) {
        uint32_t got = sa_ring_read(&p->ring, p->x + (size_t)p->have * 2, need);
        p->have += got;
        if (got < need) {
            /* the ring ran dry (a replug, a stalled input): stretch what is left over this block
               while it fades out, so the sound ends smoothly instead of at a hard edge */
            underrun = 1;
            deficit = need - got;
            /* the rate ramps down linearly from r so the reads end at the last real input:
               (r + r_end) / 2 * (n - 1) = what is left; no kink when at least half is there */
            double left = (double)p->have - SA_HALF - 1 - p->pos;
            if (left < 0) left = 0;
            double r1 = n > 1 ? 2 * left / (n - 1) - r : 0;
            if (r1 >= 0) {
                dr = n > 1 ? (r1 - r) / (n - 1) : 0;
            } else {
                /* less than half a block left: slow down from the rate it had (no pitch jump) to a
                   stop where the input ends, and be silent from there */
                double m = r > 0 ? 2 * left / r : 0;
                dr = m > 1 ? -r / m : -r;
                stop_at = (uint32_t)ceil(m);
                if (stop_at < 1) stop_at = 1;
            }
        }
    }

    /* fades: in after a start, out before an underrun's gap or a cut */
    uint32_t out_end = stop_at < n ? stop_at : n; /* when fading out: silent from here (an underrun fades the whole block) */
    uint32_t out_start = underrun ? 0 : (out_end > fade_out ? out_end - fade_out : 0);
    const float step_in = 1.0f / fade_in;

    if (p->gain_s < 0) p->gain_s = gain;
    const float gk = (float)(1 - exp(-1 / (0.01 * fs_out)));
    float peak = 0;
    double pos = p->pos;
    const float* T = p->table;
    for (uint32_t i = 0; i < n; i++) {
        int ip = (int)pos;
        double frac = pos - ip;
        double fp = frac * SA_PHASES;
        int ph = (int)fp;
        if (ph >= SA_PHASES) ph = SA_PHASES - 1;
        float b = (float)(fp - ph), a0 = 1 - b;
        const float* h0 = T + ph * SA_TAPS;
        const float* h1 = h0 + SA_TAPS;
        const float* xs = p->x + (size_t)(ip - (SA_HALF - 1)) * 2;
        float yl = 0, yr = 0;
        for (int k = 0; k < SA_TAPS; k++) {
            float h = a0 * h0[k] + b * h1[k];
            yl += h * xs[2 * k];
            yr += h * xs[2 * k + 1];
        }
        if ((underrun || resync) && i >= out_start) {
            uint32_t left = out_end > i ? out_end - i : 0; /* samples until silence, this one included */
            p->fade = left <= 1 ? 0.0f : p->fade - p->fade / (float)left;
        } else if (p->fade < 1) {
            p->fade += step_in;
            if (p->fade > 1) p->fade = 1;
        }
        p->gain_s += gk * (gain - p->gain_s);
        float g = p->fade * p->gain_s;
        float ol = yl * g, orr = yr * g;
        if (ol > 1) ol = 1;
        if (ol < -1) ol = -1;
        if (orr > 1) orr = 1;
        if (orr < -1) orr = -1;
        out[2 * i] = ol;
        out[2 * i + 1] = orr;
        float m = fabsf(ol) > fabsf(orr) ? fabsf(ol) : fabsf(orr);
        if (m > peak) peak = m;
        pos += r;
        r += dr;
        if (r < 0) r = 0, dr = 0;
    }

    /* drop the history behind the window */
    int drop = (int)floor(pos) - (SA_HALF - 1);
    if (drop > (int)p->have) drop = (int)p->have;
    if (drop > 0) {
        memmove(p->x, p->x + (size_t)drop * 2, (size_t)(p->have - drop) * 2 * sizeof(float));
        p->have -= drop;
        pos -= drop;
    }
    p->pos = pos;

    if (underrun) {
        p->running = 0;
        p->fade = 0;
        /* more room next time: what was missing, and then some */
        double grow = 1.5 * deficit + 16;
        if (grow < 0.25e-3 * fs_in) grow = 0.25e-3 * fs_in;
        double cap = 0.05 * fs_in; /* 50 ms */
        p->margin = p->margin + grow > cap ? cap : p->margin + grow;
        sa_inc(&p->underruns);
        /* the cause: the input is late right now (its last block is older than its interval allows), or not */
        uint32_t since = now_us - s1, nom = (uint32_t)p->tin.nominal_us;
        int input_late = nom > 0 && since > 1.5 * nom + 500;
        sa_evq_push(&p->ev_out, SA_EV_RING_EMPTY, now_us, (int32_t)deficit, (int32_t)since, input_late);
        p->calm_t0 = now_us;
        p->min_slack = 1e9;
    } else if (resync) {
        uint32_t f = sa_ring_fill(&p->ring);
        double keep = target - wait;
        if (keep < 0) keep = 0;
        if (f > keep) sa_ring_skip(&p->ring, f - (uint32_t)keep);
        rs_reset(p);
        p->fade = 0;
        p->fill_s = target;
        sa_inc(&p->resyncs);
        sa_evq_push(&p->ev_out, SA_EV_RESYNC, now_us, (int32_t)(f > keep ? f - (uint32_t)keep : 0), (int32_t)f, 0);
    } else if ((uint32_t)(now_us - p->calm_t0) >= SA_CALM_US) {
        /* stable for a while: give back some of the margin, if the smallest slack seen allows it */
        if (p->margin > 0) {
            double dec = 0.25 * p->margin;
            if (dec < 8) dec = 8;
            if (dec > p->margin) dec = p->margin;
            if (p->min_slack > dec + safety) p->margin -= dec;
        }
        p->calm_t0 = now_us;
        p->min_slack = 1e9;
    }

    float decay = (float)exp(-dt / 0.3);
    p->peak = peak > p->peak * decay ? peak : p->peak * decay;
    sa_stf(&p->st_peak, p->peak);
    sa_stf(&p->st_fill, (float)p->fill_s);
    sa_stf(&p->st_ring, (float)(p->ring_s > 0 ? p->ring_s : 0));
    sa_stf(&p->st_target, (float)target);
    sa_stf(&p->st_margin, (float)p->margin);
    sa_stf(&p->st_ppm, (float)(corr * 1e6));
    sa_st(&p->streaming, p->running ? 1u : 0u);
}

void sa_pass_pull(sa_pass* p, float* out, uint32_t frames, uint32_t now_us, float gain) {
    uint32_t gap = sa_timing_cb(&p->tout, frames, now_us);
    if (gap) {
        double nom = p->tout.nominal_us;
        if (nom > 0 && p->tout.bursts > 4 && gap > 1.5 * nom + 500) {
            /* later than the device can bridge: it played silence (exclusive mode: more than one
               period late; shared: more than the rest of its buffer) */
            double slack = p->out_slack_us > 0 ? p->out_slack_us : nom;
            int glitch = p->running && gap > nom + slack + 250;
            sa_inc(&p->out_late);
            if (glitch) sa_inc(&p->out_glitches);
            sa_evq_push(&p->ev_out, SA_EV_OUT_LATE, now_us, (int32_t)gap, (int32_t)nom, glitch);
        }
    }
    /* the output's biggest single take: its bursts, at least its device buffer */
    double ob = sa_wmax_get(&p->tout.burst_w);
    if (p->tout.frames > ob) ob = p->tout.frames;
    if (p->out_hint > ob) ob = p->out_hint;
    if (frames > ob) ob = frames;
    while (frames > 0) {
        uint32_t n = frames > SA_MAXBLOCK ? SA_MAXBLOCK : frames;
        pull_block(p, out, n, now_us, gain, ob);
        out += (size_t)n * 2;
        frames -= n;
        now_us += (uint32_t)(n * 1e6 / p->fs_out);
    }
}

void sa_meter(const float* in, uint32_t frames, double fs, float* peak_l, float* peak_r) {
    float l = 0, r = 0;
    for (uint32_t i = 0; i < frames; i++) {
        float a = fabsf(in[2 * i]), b = fabsf(in[2 * i + 1]);
        if (a > l) l = a;
        if (b > r) r = b;
    }
    float decay = (float)exp(-(double)frames / (0.3 * fs));
    *peak_l = l > *peak_l * decay ? l : *peak_l * decay;
    *peak_r = r > *peak_r * decay ? r : *peak_r * decay;
}

/* ---------------------------------------------------------------- WAV writer */

static void put16(unsigned char* b, uint32_t v) {
    b[0] = (unsigned char)v;
    b[1] = (unsigned char)(v >> 8);
}
static void put32(unsigned char* b, uint32_t v) {
    b[0] = (unsigned char)v;
    b[1] = (unsigned char)(v >> 8);
    b[2] = (unsigned char)(v >> 16);
    b[3] = (unsigned char)(v >> 24);
}

static int wav_header(sa_wav* w, unsigned char* h) {
    int bytes = w->bits == 16 ? 2 : (w->bits == 24 ? 3 : 4);
    uint32_t block = (uint32_t)(bytes * w->channels);
    int fl = w->bits < 0;
    uint64_t pad = w->data_bytes & 1;
    uint32_t off = 0;
    memcpy(h, "RIFF", 4);
    put32(h + 4, (uint32_t)((fl ? 50 : 36) + w->data_bytes + pad));
    memcpy(h + 8, "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);
    put32(h + 16, fl ? 18 : 16);
    put16(h + 20, fl ? 3 : 1); /* WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM */
    put16(h + 22, (uint32_t)w->channels);
    put32(h + 24, w->rate);
    put32(h + 28, w->rate * block);
    put16(h + 32, block);
    put16(h + 34, (uint32_t)(bytes * 8));
    off = 36;
    if (fl) {
        put16(h + 36, 0); /* cbSize */
        memcpy(h + 38, "fact", 4);
        put32(h + 42, 4);
        put32(h + 46, w->frames);
        off = 50;
    }
    memcpy(h + off, "data", 4);
    put32(h + off + 4, (uint32_t)w->data_bytes);
    return (int)(off + 8);
}

int sa_wav_begin(sa_wav* w, void* f, uint32_t rate, int channels, int bits) {
    memset(w, 0, sizeof(*w));
    if (!f || (bits != 16 && bits != 24 && bits != -32) || channels < 1 || channels > 8) return SA_ERR_BAD_ARG;
    w->f = f;
    w->bits = bits;
    w->channels = channels;
    w->rate = rate;
    unsigned char h[64];
    int len = wav_header(w, h);
    w->data_offset = (uint32_t)len;
    w->tmp_frames = 4096;
    w->tmp = (unsigned char*)malloc((size_t)w->tmp_frames * channels * 4);
    if (!w->tmp) return SA_ERR_FILE;
    setvbuf((FILE*)f, NULL, _IOFBF, 1 << 16);
    if (fwrite(h, 1, (size_t)len, (FILE*)f) != (size_t)len) {
        w->error = SA_ERR_FILE;
        return SA_ERR_FILE;
    }
    return SA_OK;
}

static int32_t to_int(float x, double scale, int32_t lo, int32_t hi) {
    double v = floor((double)x * scale + 0.5);
    if (v < lo) return lo;
    if (v > hi) return hi;
    return (int32_t)v;
}

int sa_wav_write(sa_wav* w, const float* src, uint32_t frames) {
    if (w->error) return w->error;
    int bytes = w->bits == 16 ? 2 : (w->bits == 24 ? 3 : 4);
    while (frames > 0) {
        uint32_t n = frames > w->tmp_frames ? w->tmp_frames : frames;
        size_t samples = (size_t)n * w->channels;
        size_t len = samples * bytes;
        if (w->data_bytes + len > SA_WAV_MAX_DATA) {
            w->error = SA_ERR_FILE_FULL;
            return w->error;
        }
        unsigned char* o = w->tmp;
        for (size_t i = 0; i < samples; i++) {
            float x = src[i];
            if (w->bits == 16) {
                int32_t v = to_int(x, 32768.0, -32768, 32767);
                o[0] = (unsigned char)v;
                o[1] = (unsigned char)(v >> 8);
                o += 2;
            } else if (w->bits == 24) {
                int32_t v = to_int(x, 8388608.0, -8388608, 8388607);
                o[0] = (unsigned char)v;
                o[1] = (unsigned char)(v >> 8);
                o[2] = (unsigned char)(v >> 16);
                o += 3;
            } else {
                uint32_t u;
                memcpy(&u, &x, 4);
                put32(o, u);
                o += 4;
            }
        }
        if (fwrite(w->tmp, 1, len, (FILE*)w->f) != len) {
            w->error = SA_ERR_FILE;
            return w->error;
        }
        w->data_bytes += len;
        w->frames += n;
        src += samples;
        frames -= n;
    }
    return SA_OK;
}

int sa_wav_update_header(sa_wav* w) {
    if (!w->f) return SA_ERR_FILE;
    unsigned char h[64];
    int len = wav_header(w, h);
    FILE* f = (FILE*)w->f;
    if (fflush(f) != 0 || fseek(f, 0, SEEK_SET) != 0 || fwrite(h, 1, (size_t)len, f) != (size_t)len || fseek(f, 0, SEEK_END) != 0 || fflush(f) != 0) {
        if (!w->error) w->error = SA_ERR_FILE;
        return SA_ERR_FILE;
    }
    return SA_OK;
}

int sa_wav_end(sa_wav* w) {
    int rc = SA_OK;
    if (!w->f) return SA_ERR_FILE;
    FILE* f = (FILE*)w->f;
    if (w->data_bytes & 1) {
        unsigned char z = 0;
        if (fwrite(&z, 1, 1, f) != 1) rc = SA_ERR_FILE;
    }
    if (sa_wav_update_header(w) != SA_OK) rc = SA_ERR_FILE;
    if (fclose(f) != 0) rc = SA_ERR_FILE;
    w->f = NULL;
    free(w->tmp);
    w->tmp = NULL;
    if (rc == SA_OK && w->error && w->error != SA_ERR_FILE_FULL) rc = w->error;
    return rc;
}
