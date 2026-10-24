/* The audio math of striso_audio, free of devices and threads so the self-test can run it on a
 * simulated clock: atomics, a lock-free single-producer single-consumer ring, a windowed-sinc
 * resampler and the passthrough (ring + resampler + drift servo + fades + gain).
 *
 * The passthrough, input clock to output clock:
 *   capture callback  -> sa_pass_push: frames into the ring, the time of the block noted
 *   playback callback -> sa_pass_pull: the "virtual fill" (ring + resampler backlog + the frames
 *       the input has produced since its last block, from the time) is smoothed and held at a
 *       target by a PI servo on the resampling ratio, so the ring neither runs dry nor fills up
 *       when the two devices' clocks differ (they always do: the Striso runs on its codec clock).
 *       A correction of 100 ppm is 0.17 cents: inaudible.
 * The target is what the ring must hold so the output never finds it empty: the longest wait for
 * the input (its largest interval between bursts, measured over the last half minute) + the output's
 * largest single take + the resampler's look-ahead + a small safety, + a margin that grows after an
 * underrun and shrinks again after stable playing (hysteresis: only when the smallest slack seen
 * allows it). Measuring bursts, not callbacks, matters: miniaudio splits a device buffer into
 * several callbacks, and a shared-mode input brings ten 1 ms packets at once.
 * Underrun: the block fades out, the output primes again and fades in. Too full (after a stall):
 * fade out, cut back to the target, fade in.
 */
#ifndef SA_CORE_H
#define SA_CORE_H

#include <stdint.h>
#include <string.h>

/* ---------------------------------------------------------------- atomics (32 bit, pointers) */
#if defined(_MSC_VER)
#include <intrin.h>
static __inline uint32_t sa_ld(volatile uint32_t* p) { return (uint32_t)_InterlockedOr((volatile long*)p, 0); }
static __inline void sa_st(volatile uint32_t* p, uint32_t v) { _InterlockedExchange((volatile long*)p, (long)v); }
static __inline uint32_t sa_inc(volatile uint32_t* p) { return (uint32_t)_InterlockedIncrement((volatile long*)p); }
static __inline uint32_t sa_addu(volatile uint32_t* p, uint32_t v) { return (uint32_t)_InterlockedExchangeAdd((volatile long*)p, (long)v) + v; }
static __inline void* sa_ldp(void* volatile* p) { return _InterlockedCompareExchangePointer(p, 0, 0); }
static __inline void sa_stp(void* volatile* p, void* v) { _InterlockedExchangePointer(p, v); }
#else
static inline uint32_t sa_ld(volatile uint32_t* p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void sa_st(volatile uint32_t* p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint32_t sa_inc(volatile uint32_t* p) { return __atomic_add_fetch(p, 1u, __ATOMIC_ACQ_REL); }
static inline uint32_t sa_addu(volatile uint32_t* p, uint32_t v) { return __atomic_add_fetch(p, v, __ATOMIC_ACQ_REL); }
static inline void* sa_ldp(void* volatile* p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void sa_stp(void* volatile* p, void* v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
#endif

static __inline float sa_ldf(volatile uint32_t* p) {
    uint32_t u = sa_ld(p);
    float f;
    memcpy(&f, &u, 4);
    return f;
}
static __inline void sa_stf(volatile uint32_t* p, float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    sa_st(p, u);
}

/* ---------------------------------------------------------------- ring (stereo float frames) */
typedef struct sa_ring {
    float* buf;
    uint32_t cap;          /* frames, a power of two */
    volatile uint32_t w;   /* frames written (wraps); only the producer stores it */
    volatile uint32_t r;   /* frames read (wraps); only the consumer stores it */
} sa_ring;

int sa_ring_init(sa_ring* rb, uint32_t min_frames); /* 0 ok */
void sa_ring_free(sa_ring* rb);
uint32_t sa_ring_fill(sa_ring* rb);                                     /* either side */
uint32_t sa_ring_write(sa_ring* rb, const float* src, uint32_t frames); /* producer; frames written */
uint32_t sa_ring_read(sa_ring* rb, float* dst, uint32_t frames);        /* consumer; frames read */
void sa_ring_skip(sa_ring* rb, uint32_t frames);                        /* consumer */

/* ---------------------------------------------------------------- resampler */
#define SA_TAPS 64
#define SA_HALF (SA_TAPS / 2)
#define SA_PHASES 256
#define SA_MAXBLOCK 2048     /* output frames per inner step (longer pulls are split) */
#define SA_MAXRATIO 4.0      /* input frames per output frame, at most */
#define SA_HIST (SA_TAPS + (int)(SA_MAXBLOCK * SA_MAXRATIO) + 16)

/* Fills table ((SA_PHASES + 1) * SA_TAPS) with Kaiser-windowed sinc kernels, cutoff relative to
 * the input's Nyquist, each phase normalised to unity gain at DC. */
void sa_sinc_table(float* table, double cutoff, double beta);

/* ---------------------------------------------------------------- timing of one side */

/* A device's callbacks seen as bursts: callbacks that follow each other within SA_BURST_US are one
 * burst (miniaudio splits a device buffer into several callbacks; Windows' shared-mode input
 * delivers ten 1 ms packets at once). Kept by the side's own thread; the results are published as
 * atomics for the other threads. */
#define SA_BURST_US 500u
#define SA_WBUCKETS 8          /* windowed maxima: 8 buckets ... */
#define SA_WBUCKET_US 4000000u /* ... of 4 s: the last 28..32 s */

typedef struct sa_wmax {
    float b[SA_WBUCKETS];
    int i;
    uint32_t t0;
    int started;
} sa_wmax;

void sa_wmax_put(sa_wmax* w, float v, uint32_t now_us);
float sa_wmax_get(const sa_wmax* w);

typedef struct sa_timing {
    int have;               /* a burst has started */
    uint32_t start_us;      /* when the current burst started */
    uint32_t end_us;        /* when its last callback was */
    uint32_t frames;        /* frames in the current burst */
    uint32_t bursts;        /* bursts completed */
    double nominal_us;      /* typical interval between burst starts (0: not known yet) */
    double burst_s;         /* typical burst size (frames, smoothed) */
    uint32_t max_gap_us;    /* largest interval since the start */
    uint32_t last_gap_us;
    sa_wmax gap_w, burst_w; /* the largest interval and burst over the last half minute */
    /* published */
    volatile uint32_t st_nominal_us, st_max_gap_us, st_recent_gap_us, st_burst, st_burst_max;
} sa_timing;

/* A callback of `frames` at now_us. Returns the interval (us) when it starts a new burst, else 0. */
uint32_t sa_timing_cb(sa_timing* t, uint32_t frames, uint32_t now_us);

/* ---------------------------------------------------------------- events */

/* What happened, for the log and the dropout counters (SA_EV_* in striso_audio.h). One queue per
 * producer thread (capture, playback), drained by the control thread. */
#define SA_EVQ 64
typedef struct sa_evq_item {
    int32_t type;
    uint32_t t_us;
    int32_t a, b, c;
} sa_evq_item;

typedef struct sa_evq {
    sa_evq_item it[SA_EVQ];
    volatile uint32_t w, r;
    volatile uint32_t lost;
} sa_evq;

void sa_evq_push(sa_evq* q, int32_t type, uint32_t t_us, int32_t a, int32_t b, int32_t c); /* producer */
int sa_evq_pop(sa_evq* q, sa_evq_item* out);                                              /* consumer: 1 if one */

/* ---------------------------------------------------------------- passthrough */
typedef struct sa_pass {
    sa_ring ring;
    /* producer side (capture thread) */
    volatile uint32_t stamp_us;   /* when the last input block arrived */
    volatile uint32_t last_block; /* its size in frames */
    volatile uint32_t overruns;
    volatile uint32_t pushes;
    volatile uint32_t in_late;    /* input bursts later than they should be */
    volatile uint32_t st_in_gap;  /* float: the largest input interval of the last half minute, input frames */
    volatile uint32_t st_in_burst;/* float: the largest input burst of the last half minute, frames */
    volatile uint32_t last_in_gap_us; /* the interval before the latest input burst */
    sa_timing tin;
    sa_evq ev_in;

    /* consumer side (playback thread) */
    double fs_in, fs_out, ratio_nom;
    float* table;
    float* x;           /* SA_HIST stereo frames of input history */
    uint32_t have;      /* valid frames in x */
    double pos;         /* read position in x (frames) */
    int running;        /* 0: priming (silence until the ring reaches the target) */
    int started;        /* has run once (the servo state is kept across underruns) */
    float fade;         /* 0..1 */
    float gain_s;       /* smoothed gain */
    double integ, fill_s, target, margin;
    double in_hint;     /* the input device's buffer (frames): the smallest interval to plan for */
    double out_hint;    /* the output device's buffer (output frames): the smallest burst to plan for */
    double out_slack_us;/* how late an output burst may be before the device runs dry (0: one interval) */
    uint32_t out_period;
    double target_used; /* the target with hysteresis */
    uint32_t calm_since_us, calm_t0; /* tightening: no underrun since; the window's start */
    double min_slack;   /* the smallest margin before a pull in this window (input frames) */
    uint32_t clamp_us;  /* when the servo last reported hitting its limit */
    uint32_t stream_us; /* when it last started playing */
    int clamped;
    sa_timing tout;
    sa_evq ev_out;

    /* statistics, read by the control thread */
    volatile uint32_t underruns, resyncs, streaming, out_late, out_glitches, clamps, retargets;
    volatile uint32_t st_fill;    /* float: smoothed virtual fill, input frames */
    volatile uint32_t st_ring;    /* float: mean delay in the ring and the resampler, input frames */
    volatile uint32_t st_target;  /* float: input frames */
    volatile uint32_t st_ppm;     /* float */
    volatile uint32_t st_peak;    /* float: output peak (decaying) */
    volatile uint32_t st_margin;  /* float: the extra margin after underruns, input frames */
    double ring_s;
    float peak;
    double fixed_ratio; /* tests: > 0 replaces the servo */
    sa_wmax slack_w;    /* the lowest slack of the last half minute (as 1e6 - slack): the margin follows it */
    uint32_t grow_us;   /* when the margin last grew for a low slack */
    float* tap;         /* measurements: when set (by the caller, for one pull), the output before the fades and the
                           gain, stereo, as many frames as the pull (0 while priming) */
} sa_pass;

/* in_hint: the input device's buffer in frames; out_hint: the output device's (output frames);
 * out_slack_us: how late an output burst may come before the device plays silence (exclusive mode:
 * one period; shared: the rest of the buffer). Hints are floors; the target follows what arrives. */
int sa_pass_init(sa_pass* p, double fs_in, double fs_out, uint32_t in_hint);
void sa_pass_set_output(sa_pass* p, uint32_t out_hint, double out_slack_us);
void sa_pass_free(sa_pass* p);
void sa_pass_push(sa_pass* p, const float* in, uint32_t frames, uint32_t now_us);
void sa_pass_pull(sa_pass* p, float* out, uint32_t frames, uint32_t now_us, float gain);

/* Peak of a stereo block per channel, folded into decaying meters (tau about 300 ms). */
void sa_meter(const float* in, uint32_t frames, double fs, float* peak_l, float* peak_r);

/* ---------------------------------------------------------------- WAV writer */
typedef struct sa_wav {
    void* f;              /* FILE* */
    int bits;             /* 16, 24, -32 (float) */
    int channels;
    uint32_t rate;
    uint32_t data_offset; /* where the samples start */
    uint64_t data_bytes;
    uint32_t frames;
    int error;            /* SA_ERR_* once a write failed */
    unsigned char* tmp;   /* conversion buffer */
    uint32_t tmp_frames;
} sa_wav;

/* f: an open FILE* (binary, write). 0 ok. */
int sa_wav_begin(sa_wav* w, void* f, uint32_t rate, int channels, int bits);
/* Interleaved float frames, converted to the file's format. 0 ok, else an SA_ERR_*. */
int sa_wav_write(sa_wav* w, const float* src, uint32_t frames);
/* Writes the RIFF and data sizes for what is in the file now (the file stays open, at its end). */
int sa_wav_update_header(sa_wav* w);
/* Updates the header, closes the file. 0 ok. */
int sa_wav_end(sa_wav* w);
/* The largest data size a RIFF file holds (with some room). */
#define SA_WAV_MAX_DATA 0xFFF00000ull

#endif
