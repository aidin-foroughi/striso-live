/* striso_audio: the Striso's USB audio input through the computer (see striso_audio.h).
 *
 * Threads:
 *   control thread (this file)  owns the miniaudio context and the devices: applies the wanted
 *       state (sa_configure), enumerates, notices lost devices, writes the WAV file, drains the
 *       callbacks' event queues into the event log, publishes the status. Initialises COM for
 *       WASAPI on itself; MMCSS "Pro Audio" at normal priority (Windows).
 *   capture callback            meters, pushes into the passthrough ring and the recording ring
 *   playback callback           pulls from the passthrough (resampler + drift servo + gain)
 * The callbacks never lock, allocate, log or touch the disk: they use atomics and lock-free
 * single-producer queues only, and the one system call they make (raising their MMCSS priority)
 * happens once per thread. The caller's threads (Dart) only take the request lock for a few copies,
 * which the callbacks never take.
 *
 * Real time (Windows): miniaudio's device threads run at THREAD_PRIORITY_TIME_CRITICAL
 * (context threadPriority) and register with MMCSS "Pro Audio" when the device starts
 * (wasapi.usage); the first callback on each thread raises that task to AVRT_PRIORITY_CRITICAL
 * (registering only when miniaudio's did not happen). timeBeginPeriod(1) is held while a device is
 * open; the process opts out of power throttling. Exclusive mode is event driven with one device
 * period per buffer (WASAPI double-buffers it), at least the device's minimum period.
 * macOS: Core Audio's HAL IO thread is real time already; the IO buffer size is set per device by
 * miniaudio (kAudioDevicePropertyBufferFrameSize, within the device's range).
 */
#include "striso_audio.h"
#include "sa_core.h"
#include "sa_platform.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_GENERATION
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#define MA_ENABLE_COREAUDIO
#define MA_ENABLE_NULL
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#define SA_MAXDEV 64
#define SA_NAME 256
#define SA_EVLOG 512

typedef struct {
    char input[SA_NAME], output[SA_NAME];
    int32_t run, period, monitor, exclusive;
} sa_want;

static struct {
    int inited;
    int32_t backend;
    ma_context ctx;
    ma_mutex lock; /* requests, device lists, published status, the event log */
    sa_thread thread;
    volatile uint32_t quit;
    volatile uint32_t ready; /* 1: context up, 2: failed */
    uint64_t t0_us;          /* sa_init's time: the events' zero */

    /* requests (under lock) */
    sa_want want;
    uint32_t want_gen;
    char rec_path[2048];
    int32_t rec_on;
    uint32_t rec_gen;
    uint32_t enum_req;

    /* control thread only */
    sa_want cur;
    uint32_t cur_gen, cur_rec_gen, enum_done;
    ma_device cap, play;
    int cap_open, play_open;
    int32_t cap_state, cap_error, cap_result, play_state, play_error, play_result;
    int32_t cap_buffer, cap_dmin, cap_ddef, cap_lat, cap_excl_result;
    int32_t play_buffer, play_dmin, play_ddef, play_lat, play_excl_result, play_transport;
    int32_t rt_control, timer_1ms, power_off;
    int32_t rec_bits_choice;
    sa_pass* pass_owned;
    sa_ring rec_ring;
    int rec_open;
    sa_wav wav;
    int32_t rec_state, rec_error, rec_bits;
    uint32_t rec_header_us;
    uint32_t wd_count, wd_us; /* watchdog: capture callbacks seen and when they last moved */
    uint32_t mic_asked;
    int32_t mic;     /* the last answer of sa_mic_status (asking costs a call to the system) */
    uint32_t mic_us; /* when */
    /* counters of passthroughs already closed (the status counts since the output opened) */

    /* shared with the audio callbacks */
    void* volatile pass; /* sa_pass* */
    void* volatile rec;  /* sa_ring* */
    volatile uint32_t cb_enter, cb_exit;
    volatile uint32_t cap_closing, play_closing, cap_lost_evt, play_lost_evt;
    volatile uint32_t cap_callbacks, play_callbacks;
    volatile uint32_t gain_bits, lvl_l, lvl_r, rec_dropped;
    volatile uint32_t cap_tid, play_tid, rt_cap, rt_play;
    volatile uint32_t jit_us, jit_every, jit_out, jit_n_cap, jit_n_play;
    sa_evq ev_cap, ev_play; /* the callbacks' own events (real-time setup) */
    float peak_l, peak_r;   /* capture callback's meter state */

    /* published (under lock) */
    sa_status st;
    sa_device caps[SA_MAXDEV], plays[SA_MAXDEV];
    int ncap, nplay;
    volatile uint32_t devices_gen;
    sa_event evlog[SA_EVLOG];
    uint32_t ev_seq;
    uint32_t ev_lost;
    uint64_t ev_last_t;
} G;

/* ======================================================================== small helpers */

static void copy_name(char* dst, const char* src) {
    size_t n = src ? strlen(src) : 0;
    if (n >= SA_NAME) n = SA_NAME - 1;
    if (n) memcpy(dst, src, n);
    dst[n] = 0;
}

static int contains_ci(const char* hay, const char* needle) {
    size_t n = strlen(needle);
    for (; *hay; hay++) {
        size_t i = 0;
        while (i < n && hay[i] && tolower((unsigned char)hay[i]) == tolower((unsigned char)needle[i])) i++;
        if (i == n) return 1;
    }
    return 0;
}

static int32_t bits_of(ma_format f) {
    switch (f) {
        case ma_format_s16: return 16;
        case ma_format_s24: return 24;
        case ma_format_s32: return 32;
        case ma_format_f32: return -32;
        default: return 0;
    }
}

/* the device's own sample format: the best integer one it lists, else float */
static void native_format(const ma_device_info* info, int32_t* bits, int32_t* rate, int32_t* ch) {
    int32_t b = 0, r = 0, c = 0;
    for (ma_uint32 i = 0; i < info->nativeDataFormatCount; i++) {
        int32_t fb = bits_of(info->nativeDataFormats[i].format);
        int better = (fb > 0 && (b <= 0 || fb > b)) || (fb < 0 && b == 0);
        if (better) {
            b = fb;
            r = (int32_t)info->nativeDataFormats[i].sampleRate;
            c = (int32_t)info->nativeDataFormats[i].channels;
        }
    }
    *bits = b;
    *rate = r;
    *ch = c;
}

static int is_striso(const ma_device_info* d) {
    if (G.backend != SA_BACKEND_SYSTEM) return 0;
#if defined(_WIN32)
    return sa_is_striso_endpoint_w(d->id.wasapi);
#elif defined(__APPLE__)
    return sa_is_striso_uid(d->id.coreaudio);
#else
    (void)d;
    return 0;
#endif
}

/* a stable id and the connection of a device (by its miniaudio id) */
static void id_text(const ma_device_id* id, const char* name, char* out) {
    out[0] = 0;
    if (G.backend == SA_BACKEND_SYSTEM) {
#if defined(_WIN32)
        sa_wide_to_utf8(id->wasapi, out, SA_NAME);
#elif defined(__APPLE__)
        copy_name(out, id->coreaudio);
#endif
    }
    if (!out[0]) copy_name(out, name);
}

static int32_t transport_of(const ma_device_id* id) {
    if (G.backend != SA_BACKEND_SYSTEM) return SA_TRANSPORT_UNKNOWN;
#if defined(_WIN32)
    return sa_transport_endpoint_w(id->wasapi);
#elif defined(__APPLE__)
    return sa_transport_uid(id->coreaudio);
#else
    (void)id;
    return SA_TRANSPORT_UNKNOWN;
#endif
}

/* waits until a capture callback that may hold an old pointer has returned */
static int quiesce_capture(void) {
    uint32_t e = sa_ld(&G.cb_enter);
    for (int i = 0; i < 500; i++) {
        if ((int32_t)(sa_ld(&G.cb_exit) - e) >= 0) return 1;
        sa_sleep_ms(1);
    }
    return 0;
}

/* ======================================================================== event log */

/* the callbacks' 32-bit microsecond stamps, extended against the 64-bit clock (they are at most
 * seconds old when drained) */
static uint64_t ev_time(uint32_t t32) {
    uint64_t now = sa_now_us64();
    uint64_t t = now - (uint32_t)((uint32_t)now - t32);
    return t > G.t0_us ? t - G.t0_us : 0;
}

static void log_event(int32_t type, uint64_t t_us, int32_t a, int32_t b, int32_t c) {
    ma_mutex_lock(&G.lock);
    /* the queues are drained one after the other: keep the log in time order */
    if (t_us < G.ev_last_t) t_us = G.ev_last_t;
    G.ev_last_t = t_us;
    sa_event* e = &G.evlog[G.ev_seq % SA_EVLOG];
    e->seq = ++G.ev_seq;
    e->type = type;
    e->t_lo = (uint32_t)t_us;
    e->t_hi = (uint32_t)(t_us >> 32);
    e->a = a;
    e->b = b;
    e->c = c;
    e->reserved = 0;
    ma_mutex_unlock(&G.lock);
}

static void drain_queue(sa_evq* q) {
    sa_evq_item it;
    while (sa_evq_pop(q, &it)) log_event(it.type, ev_time(it.t_us), it.a, it.b, it.c);
}

static void drain_events(void) {
    drain_queue(&G.ev_cap);
    drain_queue(&G.ev_play);
    sa_pass* p = G.pass_owned;
    if (p) {
        drain_queue(&p->ev_in);
        drain_queue(&p->ev_out);
    }
}

/* an event of the control thread, after what the callbacks reported before it */
static void log_now(int32_t type, int32_t a, int32_t b, int32_t c) {
    drain_events();
    log_event(type, sa_now_us64() - G.t0_us, a, b, c);
}

static uint32_t events_lost(void) {
    uint32_t n = G.ev_lost + sa_ld(&G.ev_cap.lost) + sa_ld(&G.ev_play.lost);
    sa_pass* p = G.pass_owned;
    if (p) n += sa_ld(&p->ev_in.lost) + sa_ld(&p->ev_out.lost);
    return n;
}

/* ======================================================================== callbacks */

static void* mmcss_handle(ma_device* d) {
#if defined(_WIN32)
    return G.backend == SA_BACKEND_SYSTEM ? d->wasapi.hAvrtHandle : NULL;
#else
    (void)d;
    return NULL;
#endif
}

/* once per device thread: its real-time priority (one system call, then never again) */
static void rt_once(ma_device* d, volatile uint32_t* tid, volatile uint32_t* flags, sa_evq* q, int capture) {
    uint32_t t = sa_thread_id();
    if (t == sa_ld(tid)) return;
    sa_st(tid, t);
    uint32_t f = G.backend == SA_BACKEND_SYSTEM ? (uint32_t)sa_rt_device_thread(mmcss_handle(d)) : 0u;
    sa_st(flags, f);
    sa_evq_push(q, SA_EV_RT, sa_now_us(), capture, (int32_t)f, 0);
}

/* tests on the null backend: a late callback */
static void jitter(volatile uint32_t* n) {
    uint32_t us = sa_ld(&G.jit_us), every = sa_ld(&G.jit_every);
    if (!us || !every || G.backend != SA_BACKEND_NULL) return;
    uint32_t k = sa_inc(n);
    if (k % every) return;
    /* 1 ms .. us, spread over the callbacks */
    uint32_t span = us > 1000 ? us - 1000 : 0;
    uint32_t late = 1000 + (span ? (k * 2654435761u) % span : 0);
    sa_sleep_ms((int)((late + 500) / 1000));
}

static void capture_cb(ma_device* d, void* out, const void* in, ma_uint32 n) {
    (void)out;
    sa_inc(&G.cb_enter);
    rt_once(d, &G.cap_tid, &G.rt_cap, &G.ev_cap, 1);
    jitter(&G.jit_n_cap);
    const float* x = (const float*)in;
    if (x && d->capture.channels == 2) {
        uint32_t now = sa_now_us();
        sa_meter(x, n, (double)d->sampleRate, &G.peak_l, &G.peak_r);
        sa_stf(&G.lvl_l, G.peak_l);
        sa_stf(&G.lvl_r, G.peak_r);
        sa_pass* p = (sa_pass*)sa_ldp(&G.pass);
        if (p) sa_pass_push(p, x, n, now);
        sa_ring* r = (sa_ring*)sa_ldp(&G.rec);
        if (r) {
            uint32_t w = sa_ring_write(r, x, n);
            if (w < n) sa_addu(&G.rec_dropped, n - w);
        }
    }
    sa_inc(&G.cap_callbacks);
    sa_inc(&G.cb_exit);
}

static void playback_cb(ma_device* d, void* out, const void* in, ma_uint32 n) {
    (void)in;
    rt_once(d, &G.play_tid, &G.rt_play, &G.ev_play, 0);
    if (sa_ld(&G.jit_out)) jitter(&G.jit_n_play);
    sa_pass* p = (sa_pass*)sa_ldp(&G.pass);
    if (p && d->playback.channels == 2) {
        sa_pass_pull(p, (float*)out, n, sa_now_us(), sa_ldf(&G.gain_bits));
    } else {
        memset(out, 0, (size_t)n * d->playback.channels * sizeof(float));
    }
    sa_inc(&G.play_callbacks);
}

static void notify_cb(const ma_device_notification* nt) {
    if (nt->type != ma_device_notification_type_stopped) return;
    if (nt->pDevice == &G.cap && !sa_ld(&G.cap_closing)) sa_st(&G.cap_lost_evt, 1);
    if (nt->pDevice == &G.play && !sa_ld(&G.play_closing)) sa_st(&G.play_lost_evt, 1);
}

/* ======================================================================== devices */

static ma_bool32 find_device(ma_device_type type, const char* name, ma_device_id* id, ma_device_info* info) {
    ma_device_info *pp = NULL, *pc = NULL;
    ma_uint32 np = 0, nc = 0;
    if (ma_context_get_devices(&G.ctx, &pp, &np, &pc, &nc) != MA_SUCCESS) return MA_FALSE;
    ma_device_info* list = type == ma_device_type_capture ? pc : pp;
    ma_uint32 n = type == ma_device_type_capture ? nc : np;
    int hit = -1;
    if (name && name[0]) {
        for (ma_uint32 i = 0; i < n && hit < 0; i++)
            if (strcmp(list[i].name, name) == 0) hit = (int)i;
    } else if (type == ma_device_type_capture) {
        for (ma_uint32 i = 0; i < n && hit < 0; i++)
            if (is_striso(&list[i])) hit = (int)i;
        for (ma_uint32 i = 0; i < n && hit < 0; i++)
            if (contains_ci(list[i].name, "striso")) hit = (int)i;
    }
    if (hit < 0) return MA_FALSE;
    *id = list[hit].id;
    *info = list[hit];
    ma_device_info full;
    if (ma_context_get_device_info(&G.ctx, type, id, &full) == MA_SUCCESS) {
        info->nativeDataFormatCount = full.nativeDataFormatCount;
        memcpy(info->nativeDataFormats, full.nativeDataFormats, sizeof(full.nativeDataFormats));
    }
    return MA_TRUE;
}

static void device_periods(ma_device_type type, const ma_device_id* id, int32_t* dmin, int32_t* ddef);

static void do_enumerate(void) {
    static sa_device caps[SA_MAXDEV], plays[SA_MAXDEV];
    int nc = 0, np = 0;
    ma_device_info *pp = NULL, *pc = NULL;
    ma_uint32 cp = 0, cc = 0;
    if (ma_context_get_devices(&G.ctx, &pp, &cp, &pc, &cc) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < cc && nc < SA_MAXDEV; i++) {
            sa_device* d = &caps[nc++];
            memset(d, 0, sizeof(*d));
            copy_name(d->name, pc[i].name);
            id_text(&pc[i].id, pc[i].name, d->id);
            d->is_default = pc[i].isDefault ? 1 : 0;
            d->is_striso = is_striso(&pc[i]);
            d->transport = transport_of(&pc[i].id);
            if (d->transport != SA_TRANSPORT_BLUETOOTH) device_periods(ma_device_type_capture, &pc[i].id, &d->dev_min, &d->dev_default);
            ma_device_info full;
            if (ma_context_get_device_info(&G.ctx, ma_device_type_capture, &pc[i].id, &full) == MA_SUCCESS)
                native_format(&full, &d->native_bits, &d->native_rate, &d->native_channels);
        }
        for (ma_uint32 i = 0; i < cp && np < SA_MAXDEV; i++) {
            sa_device* d = &plays[np++];
            memset(d, 0, sizeof(*d));
            copy_name(d->name, pp[i].name);
            id_text(&pp[i].id, pp[i].name, d->id);
            d->is_default = pp[i].isDefault ? 1 : 0;
            d->transport = transport_of(&pp[i].id);
            if (d->transport != SA_TRANSPORT_BLUETOOTH) device_periods(ma_device_type_playback, &pp[i].id, &d->dev_min, &d->dev_default);
        }
    }
    ma_mutex_lock(&G.lock);
    memcpy(G.caps, caps, sizeof(sa_device) * (size_t)nc);
    memcpy(G.plays, plays, sizeof(sa_device) * (size_t)np);
    G.ncap = nc;
    G.nplay = np;
    ma_mutex_unlock(&G.lock);
    sa_inc(&G.devices_gen);
}

/* Windows: the device's minimum and default period (frames), from IAudioClient::GetDevicePeriod on
 * a client that is activated but never initialised (nothing opens, nothing plays) */
static void device_periods(ma_device_type type, const ma_device_id* id, int32_t* dmin, int32_t* ddef) {
    *dmin = *ddef = 0;
#if defined(_WIN32)
    if (G.backend != SA_BACKEND_SYSTEM) return;
    ma_IMMDevice* dev = NULL;
    if (ma_context_get_MMDevice__wasapi(&G.ctx, type, id, &dev) != MA_SUCCESS || !dev) return;
    ma_IAudioClient* ac = NULL;
    if (SUCCEEDED(ma_IMMDevice_Activate(dev, &MA_IID_IAudioClient, CLSCTX_ALL, NULL, (void**)&ac)) && ac) {
        MA_REFERENCE_TIME def = 0, mn = 0;
        MA_WAVEFORMATEX* wf = NULL;
        double rate = 48000;
        if (SUCCEEDED(ma_IAudioClient_GetMixFormat(ac, &wf)) && wf) {
            rate = wf->nSamplesPerSec;
            { ma_context* cx = &G.ctx; ma_CoTaskMemFree(cx, wf); }
        }
        if (SUCCEEDED(ma_IAudioClient_GetDevicePeriod(ac, &def, &mn))) {
            *dmin = (int32_t)ceil(mn * rate / 1e7 - 1e-6);
            *ddef = (int32_t)ceil(def * rate / 1e7 - 1e-6);
        }
        ma_IAudioClient_Release(ac);
    }
    ma_IMMDevice_Release(dev);
#else
    (void)type;
    (void)id;
#endif
}

/* after init: what the device really took (its buffer per wake-up) and what the system adds */
static void device_latency(ma_device* d, int capture, int32_t* buffer, int32_t* lat) {
    *buffer = 0;
    *lat = 0;
    double rate = d->sampleRate > 0 ? d->sampleRate : 48000;
#if defined(_WIN32)
    if (G.backend == SA_BACKEND_SYSTEM) {
        ma_IAudioClient* ac = (ma_IAudioClient*)(capture ? d->wasapi.pAudioClientCapture : d->wasapi.pAudioClientPlayback);
        ma_share_mode sm = capture ? d->capture.shareMode : d->playback.shareMode;
        ma_uint32 actual = capture ? d->wasapi.actualBufferSizeInFramesCapture : d->wasapi.actualBufferSizeInFramesPlayback;
        ma_uint32 per = capture ? d->wasapi.periodSizeInFramesCapture : d->wasapi.periodSizeInFramesPlayback;
        *buffer = (int32_t)(sm == ma_share_mode_exclusive ? actual : (per ? per : actual));
        MA_REFERENCE_TIME l = 0;
        if (ac && SUCCEEDED(ma_IAudioClient_GetStreamLatency(ac, &l))) *lat = (int32_t)(l * rate / 1e7 + 0.5);
        return;
    }
#elif defined(__APPLE__)
    if (G.backend == SA_BACKEND_SYSTEM) {
        uint32_t obj = capture ? d->coreaudio.deviceObjectIDCapture : d->coreaudio.deviceObjectIDPlayback;
        int32_t b = 0, l = 0;
        if (sa_ca_latency(obj, capture, &b, &l)) {
            *buffer = b;
            *lat = l;
        }
        if (*buffer == 0) *buffer = (int32_t)(capture ? d->capture.internalPeriodSizeInFrames : d->playback.internalPeriodSizeInFrames);
        return;
    }
#endif
    (void)rate;
    *buffer = (int32_t)(capture ? d->capture.internalPeriodSizeInFrames : d->playback.internalPeriodSizeInFrames);
}

/* Windows exclusive mode: one buffer of the period per wake-up, at least the device's minimum */
static ma_uint32 exclusive_period(int32_t want, int32_t dmin) {
    ma_uint32 p = (ma_uint32)(want > 16 ? want : 16);
    if (dmin > 0 && p < (ma_uint32)dmin) p = (ma_uint32)dmin;
    return p;
}

/* ------------------------------------------------------------------------ recording */

static void rec_drain_all(void) {
    static float buf[4096 * 2];
    uint32_t n;
    while ((n = sa_ring_read(&G.rec_ring, buf, 4096)) > 0) {
        if (sa_wav_write(&G.wav, buf, n) != SA_OK) {
            /* keep draining so the ring empties; the error is reported once stopped */
            continue;
        }
    }
}

static void rec_stop(int32_t state, int32_t err) {
    if (!G.rec_open) return;
    sa_stp(&G.rec, NULL);
    if (!quiesce_capture()) {
        /* the capture thread is stuck: leave the ring to it rather than free it under it */
        G.rec_open = 0;
        sa_wav_end(&G.wav);
        G.rec_state = SA_REC_STOPPED;
        G.rec_error = SA_ERR_FILE;
        return;
    }
    rec_drain_all();
    int werr = G.wav.error;
    int rc = sa_wav_end(&G.wav);
    sa_ring_free(&G.rec_ring);
    G.rec_open = 0;
    G.rec_state = state;
    G.rec_error = err != SA_OK ? err : (werr ? werr : (rc != SA_OK ? rc : SA_OK));
    if (G.rec_error != SA_OK) G.rec_state = SA_REC_STOPPED;
}

static void rec_start(const char* path) {
    if (G.rec_open) rec_stop(SA_REC_IDLE, SA_OK);
    if (!G.cap_open) {
        G.rec_state = SA_REC_STOPPED;
        G.rec_error = SA_ERR_NOT_RUNNING;
        return;
    }
    FILE* f = sa_fopen_utf8(path, "wb");
    if (!f) {
        G.rec_state = SA_REC_STOPPED;
        G.rec_error = SA_ERR_FILE;
        return;
    }
    int32_t bits = G.rec_bits_choice;
    if (sa_wav_begin(&G.wav, f, G.cap.sampleRate, 2, bits) != SA_OK || sa_ring_init(&G.rec_ring, G.cap.sampleRate * 3) != 0) {
        if (G.wav.f) sa_wav_end(&G.wav);
        else fclose(f);
        G.rec_state = SA_REC_STOPPED;
        G.rec_error = SA_ERR_FILE;
        return;
    }
    sa_st(&G.rec_dropped, 0);
    G.rec_bits = bits;
    G.rec_open = 1;
    G.rec_state = SA_REC_ON;
    G.rec_error = SA_OK;
    G.rec_header_us = sa_now_us();
    sa_stp(&G.rec, &G.rec_ring);
}

static void rec_service(void) {
    if (!G.rec_open) return;
    static float buf[4096 * 2];
    uint32_t n;
    while ((n = sa_ring_read(&G.rec_ring, buf, 4096)) > 0) {
        int rc = sa_wav_write(&G.wav, buf, n);
        if (rc != SA_OK) {
            rec_stop(SA_REC_STOPPED, rc);
            return;
        }
    }
    uint32_t now = sa_now_us();
    if (now - G.rec_header_us > 1000000u) {
        /* a crash or a pulled plug still leaves a readable file */
        G.rec_header_us = now;
        if (sa_wav_update_header(&G.wav) != SA_OK) rec_stop(SA_REC_STOPPED, SA_ERR_FILE);
    }
}

/* ------------------------------------------------------------------------ open / close */

static void timer_follow(void) {
    if (G.backend != SA_BACKEND_SYSTEM) return;
    G.timer_1ms = sa_timer_1ms(G.cap_open || G.play_open);
}

static void close_playback(int32_t state, int32_t err) {
    if (G.play_open) {
        sa_st(&G.play_closing, 1);
        ma_device_uninit(&G.play); /* joins its thread: no playback callback after this */
        sa_st(&G.play_closing, 0);
        G.play_open = 0;
    }
    sa_st(&G.play_lost_evt, 0);
    sa_st(&G.play_tid, 0);
    sa_st(&G.rt_play, 0);
    sa_pass* p = G.pass_owned;
    if (p) {
        sa_stp(&G.pass, NULL);
        if (quiesce_capture()) {
            drain_events();
            G.ev_lost += sa_ld(&p->ev_in.lost) + sa_ld(&p->ev_out.lost);
            G.pass_owned = NULL;
            sa_pass_free(p);
            free(p);
        } /* else leaked on purpose: the capture thread may still hold it */
        G.pass_owned = NULL;
    }
    G.play_state = state;
    G.play_error = err;
    G.play_buffer = G.play_lat = 0;
    timer_follow();
}

static void close_capture(int32_t state, int32_t err) {
    rec_stop(G.rec_open ? SA_REC_STOPPED : G.rec_state, state == SA_DEV_LOST ? SA_ERR_LOST : SA_OK);
    close_playback(SA_DEV_CLOSED, SA_OK);
    if (G.cap_open) {
        sa_st(&G.cap_closing, 1);
        ma_device_uninit(&G.cap);
        sa_st(&G.cap_closing, 0);
        G.cap_open = 0;
    }
    sa_st(&G.cap_lost_evt, 0);
    sa_st(&G.cap_tid, 0);
    sa_st(&G.rt_cap, 0);
    sa_stf(&G.lvl_l, 0);
    sa_stf(&G.lvl_r, 0);
    G.peak_l = G.peak_r = 0;
    G.cap_state = state;
    G.cap_error = err;
    G.cap_buffer = G.cap_lat = 0;
    timer_follow();
}

static ma_result init_capture(const ma_device_id* id, ma_share_mode mode) {
    ma_device_config c = ma_device_config_init(ma_device_type_capture);
    c.capture.pDeviceID = id;
    c.capture.format = ma_format_f32;
    c.capture.channels = 2;
    c.capture.shareMode = mode;
    c.sampleRate = 0; /* the device's own: the resampler bridges */
    c.periodSizeInFrames = (ma_uint32)G.cur.period;
    if (mode == ma_share_mode_exclusive) {
        c.periodSizeInFrames = exclusive_period(G.cur.period, G.cap_dmin);
        c.periods = 1; /* one period per buffer: WASAPI double-buffers it itself */
    }
    c.noFixedSizedCallback = MA_TRUE; /* whole device buffers: the passthrough measures bursts */
    c.performanceProfile = ma_performance_profile_low_latency;
    c.dataCallback = capture_cb;
    c.notificationCallback = notify_cb;
    c.wasapi.usage = ma_wasapi_usage_pro_audio;
    c.wasapi.noAutoConvertSRC = MA_TRUE; /* also lets IAudioClient3 low-latency shared mode in */
    c.wasapi.noDefaultQualitySRC = MA_TRUE;
    return ma_device_init(&G.ctx, &c, &G.cap);
}

static void open_capture(void) {
    ma_device_id id;
    ma_device_info info;
    G.cap_result = 0;
    G.cap_excl_result = 0;
    if (!find_device(ma_device_type_capture, G.cur.input, &id, &info)) {
        G.cap_state = SA_DEV_FAILED;
        G.cap_error = SA_ERR_NOT_FOUND;
        return;
    }
    /* macOS asks the user before an app may use audio input (the null backend needs nobody's leave) */
    int mic = G.backend == SA_BACKEND_SYSTEM ? sa_mic_status() : SA_MIC_NA;
    G.mic = mic;
    G.mic_us = sa_now_us();
    if (mic == SA_MIC_UNDETERMINED || mic == SA_MIC_DENIED || mic == SA_MIC_RESTRICTED) {
        if (mic == SA_MIC_UNDETERMINED && !G.mic_asked) {
            G.mic_asked = 1;
            sa_mic_request();
        }
        G.cap_state = SA_DEV_FAILED;
        G.cap_error = SA_ERR_PERMISSION;
        return;
    }
    device_periods(ma_device_type_capture, &id, &G.cap_dmin, &G.cap_ddef);
    ma_result r = MA_ERROR;
#if defined(_WIN32)
    if ((G.cur.exclusive & SA_EXCLUSIVE_INPUT) && G.backend == SA_BACKEND_SYSTEM) {
        r = init_capture(&id, ma_share_mode_exclusive);
        if (r != MA_SUCCESS) G.cap_excl_result = r;
    }
#endif
    if (r != MA_SUCCESS) r = init_capture(&id, ma_share_mode_shared);
    if (r != MA_SUCCESS) {
        G.cap_state = SA_DEV_FAILED;
        G.cap_error = SA_ERR_OPEN_CAPTURE;
        G.cap_result = r;
        return;
    }
    G.cap_open = 1;
    sa_st(&G.cap_lost_evt, 0);
    device_latency(&G.cap, 1, &G.cap_buffer, &G.cap_lat);
    log_now(SA_EV_OPEN, 1, G.cap_buffer, G.cap.capture.shareMode == ma_share_mode_exclusive);
    /* the recording format follows the device */
    int32_t ib = bits_of(G.cap.capture.internalFormat), nb, nr, nch;
    native_format(&info, &nb, &nr, &nch);
    int32_t src = ib > 0 ? ib : nb;
    G.rec_bits_choice = src == 16 ? 16 : (src == 24 || src == 32 ? 24 : -32);
    r = ma_device_start(&G.cap);
    if (r != MA_SUCCESS) {
        close_capture(SA_DEV_FAILED, SA_ERR_OPEN_CAPTURE);
        G.cap_result = r;
        return;
    }
    G.wd_count = sa_ld(&G.cap_callbacks);
    G.wd_us = sa_now_us();
    G.cap_state = SA_DEV_RUNNING;
    G.cap_error = SA_OK;
    timer_follow();
}

static ma_result init_playback(const ma_device_id* id, ma_share_mode mode) {
    ma_device_config c = ma_device_config_init(ma_device_type_playback);
    c.playback.pDeviceID = id;
    c.playback.format = ma_format_f32;
    c.playback.channels = 2;
    c.playback.shareMode = mode;
    c.sampleRate = 0; /* the device's own: the resampler bridges */
    c.periodSizeInFrames = (ma_uint32)G.cur.period;
    if (mode == ma_share_mode_exclusive) {
        c.periodSizeInFrames = exclusive_period(G.cur.period, G.play_dmin);
        c.periods = 1; /* event driven, one period per buffer (WASAPI double-buffers) */
    }
    c.noFixedSizedCallback = MA_TRUE;
    c.performanceProfile = ma_performance_profile_low_latency;
    c.noPreSilencedOutputBuffer = MA_TRUE;
    c.noClip = MA_TRUE;
    c.dataCallback = playback_cb;
    c.notificationCallback = notify_cb;
    c.wasapi.usage = ma_wasapi_usage_pro_audio;
    c.wasapi.noAutoConvertSRC = MA_TRUE;
    c.wasapi.noDefaultQualitySRC = MA_TRUE;
    return ma_device_init(&G.ctx, &c, &G.play);
}

static void open_playback(void) {
    ma_device_id id;
    ma_device_info info;
    const ma_device_id* pid = NULL;
    G.play_result = 0;
    G.play_excl_result = 0;
    if (G.cur.output[0]) {
        if (!find_device(ma_device_type_playback, G.cur.output, &id, &info)) {
            G.play_state = SA_DEV_FAILED;
            G.play_error = SA_ERR_NOT_FOUND;
            return;
        }
        pid = &id;
    }
    device_periods(ma_device_type_playback, pid, &G.play_dmin, &G.play_ddef);
    ma_result r = MA_ERROR;
#if defined(_WIN32)
    if ((G.cur.exclusive & SA_EXCLUSIVE_OUTPUT) && G.backend == SA_BACKEND_SYSTEM) {
        r = init_playback(pid, ma_share_mode_exclusive); /* the device's own format and rate */
        if (r != MA_SUCCESS) G.play_excl_result = r; /* MA_BUSY: another program holds it */
    }
#endif
    if (r != MA_SUCCESS) r = init_playback(pid, ma_share_mode_shared);
    if (r != MA_SUCCESS) {
        G.play_state = SA_DEV_FAILED;
        G.play_error = SA_ERR_OPEN_PLAYBACK;
        G.play_result = r;
        return;
    }
    G.play_open = 1;
    G.play_transport = transport_of(&G.play.playback.id);
    device_latency(&G.play, 0, &G.play_buffer, &G.play_lat);
    int excl = G.play.playback.shareMode == ma_share_mode_exclusive;
    log_now(SA_EV_OPEN, 0, G.play_buffer, excl);
    sa_pass* p = (sa_pass*)malloc(sizeof(sa_pass));
    uint32_t in_hint = G.cap_buffer > 0 ? (uint32_t)G.cap_buffer : G.cap.capture.internalPeriodSizeInFrames;
    if (!p || sa_pass_init(p, (double)G.cap.sampleRate, (double)G.play.sampleRate, in_hint) != 0) {
        free(p);
        close_playback(SA_DEV_FAILED, SA_ERR_OPEN_PLAYBACK);
        return;
    }
    /* how late a playback wake-up may come before the device runs dry: exclusive, one buffer (the
       other one is playing); shared, what the buffer holds beyond one engine period */
    double slack_us = 0;
#if defined(_WIN32)
    if (G.backend == SA_BACKEND_SYSTEM) {
        double rate = G.play.sampleRate;
        ma_uint32 actual = G.play.wasapi.actualBufferSizeInFramesPlayback, per = G.play.wasapi.periodSizeInFramesPlayback;
        slack_us = excl ? actual * 1e6 / rate : (actual > per ? (actual - per) * 1e6 / rate : 0);
    }
#endif
    sa_pass_set_output(p, (uint32_t)(G.play_buffer > 0 ? G.play_buffer : 0), slack_us);
    G.pass_owned = p;
    sa_stp(&G.pass, p);
    sa_st(&G.play_lost_evt, 0);
    r = ma_device_start(&G.play);
    if (r != MA_SUCCESS) {
        close_playback(SA_DEV_FAILED, SA_ERR_OPEN_PLAYBACK);
        G.play_result = r;
        return;
    }
    G.play_state = SA_DEV_RUNNING;
    G.play_error = SA_OK;
    timer_follow();
}

static void close_all(void) {
    close_capture(SA_DEV_CLOSED, SA_OK);
    G.play_state = SA_DEV_CLOSED;
    G.play_error = SA_OK;
}

/* the wanted state, from what is open now */
static void apply(const sa_want* w) {
    sa_want old = G.cur;
    G.cur = *w;
    if (!w->run) {
        close_all();
        return;
    }
    int cap_change = !G.cap_open || strcmp(old.input, w->input) != 0 || old.period != w->period ||
                     (old.exclusive & SA_EXCLUSIVE_INPUT) != (w->exclusive & SA_EXCLUSIVE_INPUT);
    if (cap_change) {
        close_all();
        open_capture();
        if (!G.cap_open) return;
    }
    int play_change = cap_change || (w->monitor ? 1 : 0) != (G.play_open ? 1 : 0) || strcmp(old.output, w->output) != 0 ||
                      old.period != w->period || (w->monitor && !G.play_open) ||
                      (old.exclusive & SA_EXCLUSIVE_OUTPUT) != (w->exclusive & SA_EXCLUSIVE_OUTPUT);
    if (play_change) {
        close_playback(SA_DEV_CLOSED, SA_OK);
        if (w->monitor) open_playback();
    }
}

static void check_lost(void) {
    if (G.cap_open) {
        uint32_t now = sa_now_us(), cnt = sa_ld(&G.cap_callbacks);
        if (cnt != G.wd_count) {
            G.wd_count = cnt;
            G.wd_us = now;
        }
        uint32_t limit = 1500000u; /* 1.5 s without a capture callback: gone */
        int stalled = (now - G.wd_us) > limit;
        if (sa_ld(&G.cap_lost_evt) || stalled || ma_device_get_state(&G.cap) != ma_device_state_started) {
            close_capture(SA_DEV_LOST, SA_ERR_LOST);
            return;
        }
    }
    if (G.play_open && (sa_ld(&G.play_lost_evt) || ma_device_get_state(&G.play) != ma_device_state_started)) {
        close_playback(SA_DEV_LOST, SA_ERR_LOST);
    }
}

static void publish(void) {
    sa_status s;
    memset(&s, 0, sizeof(s));
    s.api_version = SA_API_VERSION;
    s.initialised = 1;
    s.backend = G.backend;
    s.config_gen = G.cur_gen;
    s.devices_gen = sa_ld(&G.devices_gen);
    s.capture_state = G.cap_state;
    s.capture_error = G.cap_error;
    s.capture_result = G.cap_result;
    s.capture_excl_result = G.cap_excl_result;
    s.capture_dev_min = G.cap_dmin;
    s.capture_dev_default = G.cap_ddef;
    if (G.cap_open) {
        s.capture_rate = (int32_t)G.cap.sampleRate;
        s.capture_channels = (int32_t)G.cap.capture.internalChannels;
        s.capture_period = (int32_t)G.cap.capture.internalPeriodSizeInFrames;
        s.capture_exclusive = G.cap.capture.shareMode == ma_share_mode_exclusive;
        s.capture_bits = bits_of(G.cap.capture.internalFormat);
        s.capture_buffer = G.cap_buffer;
        s.capture_stream_latency = G.cap_lat;
    }
    s.capture_callbacks = sa_ld(&G.cap_callbacks);
    s.playback_state = G.play_state;
    s.playback_error = G.play_error;
    s.playback_result = G.play_result;
    s.playback_excl_result = G.play_excl_result;
    s.playback_dev_min = G.play_dmin;
    s.playback_dev_default = G.play_ddef;
    if (G.play_open) {
        s.playback_rate = (int32_t)G.play.sampleRate;
        s.playback_period = (int32_t)G.play.playback.internalPeriodSizeInFrames;
        s.playback_periods = (int32_t)G.play.playback.internalPeriods;
        s.playback_exclusive = G.play.playback.shareMode == ma_share_mode_exclusive;
        s.playback_buffer = G.play_buffer;
        s.playback_stream_latency = G.play_lat;
        s.playback_transport = G.play_transport;
    }
    s.playback_callbacks = sa_ld(&G.play_callbacks);
    s.gain = sa_ldf(&G.gain_bits);
    sa_pass* p = G.pass_owned;
    if (p && G.cap_open && G.play_open) {
        double fs = p->fs_in;
        float ring = sa_ldf(&p->st_ring);
        s.ring_ms = (float)(ring / fs * 1000);
        s.target_ms = (float)(sa_ldf(&p->st_target) / fs * 1000);
        s.margin_ms = (float)(sa_ldf(&p->st_margin) / fs * 1000);
        s.drift_ppm = sa_ldf(&p->st_ppm);
        s.underruns = sa_ld(&p->underruns);
        s.overruns = sa_ld(&p->overruns);
        s.resyncs = sa_ld(&p->resyncs);
        s.in_late = sa_ld(&p->in_late);
        s.out_late = sa_ld(&p->out_late);
        s.out_glitches = sa_ld(&p->out_glitches);
        s.servo_limits = sa_ld(&p->clamps);
        s.retargets = sa_ld(&p->retargets);
        s.streaming = (int32_t)sa_ld(&p->streaming);
        s.level_out = sa_ldf(&p->st_peak);
        s.cap_nominal_us = sa_ld(&p->tin.st_nominal_us);
        s.cap_max_gap_us = sa_ld(&p->tin.st_max_gap_us);
        s.cap_recent_gap_us = sa_ld(&p->tin.st_recent_gap_us);
        s.cap_burst = sa_ld(&p->tin.st_burst);
        s.cap_burst_max = sa_ld(&p->tin.st_burst_max);
        s.play_nominal_us = sa_ld(&p->tout.st_nominal_us);
        s.play_max_gap_us = sa_ld(&p->tout.st_max_gap_us);
        s.play_recent_gap_us = sa_ld(&p->tout.st_recent_gap_us);
        s.play_burst = sa_ld(&p->tout.st_burst);
        s.play_burst_max = sa_ld(&p->tout.st_burst_max);
        /* the breakdown. input: the wait for the input's next wake-up (half its interval on average)
           + what the system reports for it; ring: the mean delay in the ring and the resampler;
           output: its buffer (exclusive: the one being written waits for the one playing; shared:
           the buffer is kept full, less half an engine period) + what the system reports */
        double nom_in = s.cap_nominal_us > 0 ? s.cap_nominal_us * 1e-3 : (G.cap_buffer > 0 ? G.cap_buffer / fs * 1000 : 0);
        s.in_ms = (float)(nom_in / 2 + G.cap_lat / fs * 1000);
        double pr = s.playback_rate > 0 ? s.playback_rate : 48000;
        double ob = G.play_buffer > 0 ? G.play_buffer : (double)s.playback_period * (s.playback_periods > 0 ? s.playback_periods : 1);
        double take = s.play_burst > 0 ? s.play_burst : ob;
        double out_frames = s.playback_exclusive ? ob : (ob > take / 2 ? ob - take / 2 : ob);
#if defined(_WIN32)
        if (G.backend == SA_BACKEND_SYSTEM && !s.playback_exclusive) {
            /* shared: miniaudio keeps the whole client buffer filled */
            ma_uint32 actual = G.play.wasapi.actualBufferSizeInFramesPlayback;
            if (actual > 0) out_frames = actual - take / 2 > 0 ? actual - take / 2 : actual;
        }
#endif
        s.out_ms = (float)((out_frames + G.play_lat) / pr * 1000);
        s.latency_ms = s.in_ms + s.ring_ms + s.out_ms;
    }
    s.record_state = G.rec_state;
    s.record_error = G.rec_error;
    s.record_bits = G.rec_bits;
    s.record_frames = G.wav.frames;
    s.record_dropped = sa_ld(&G.rec_dropped);
    uint32_t now = sa_now_us();
    if (G.mic_us == 0 || now - G.mic_us > 1000000u) {
        G.mic = sa_mic_status();
        G.mic_us = now | 1u;
    }
    s.mic_permission = G.mic;
    s.rt_capture = (int32_t)sa_ld(&G.rt_cap);
    s.rt_playback = (int32_t)sa_ld(&G.rt_play);
    s.rt_control = G.rt_control;
    s.timer_1ms = G.timer_1ms;
    s.power_throttling_off = G.power_off;
    s.events_lost = events_lost();
    ma_mutex_lock(&G.lock);
    s.event_seq = G.ev_seq;
    G.st = s;
    ma_mutex_unlock(&G.lock);
}

static void control_main(void* arg) {
    (void)arg;
    ma_backend backends[1];
#if defined(_WIN32)
    backends[0] = G.backend == SA_BACKEND_NULL ? ma_backend_null : ma_backend_wasapi;
#elif defined(__APPLE__)
    backends[0] = G.backend == SA_BACKEND_NULL ? ma_backend_null : ma_backend_coreaudio;
#else
    backends[0] = ma_backend_null;
#endif
    if (G.backend == SA_BACKEND_SYSTEM) {
        G.rt_control = sa_rt_control_thread();
        G.power_off = sa_power_throttling_off();
    }
    ma_context_config cc = ma_context_config_init();
    cc.threadPriority = ma_thread_priority_realtime;
    if (ma_context_init(backends, 1, &cc, &G.ctx) != MA_SUCCESS) {
        sa_st(&G.ready, 2);
        return;
    }
    publish();
    sa_st(&G.ready, 1);
    while (!sa_ld(&G.quit)) {
        sa_want want;
        char path[2048];
        ma_mutex_lock(&G.lock);
        want = G.want;
        uint32_t gen = G.want_gen, rgen = G.rec_gen, ereq = G.enum_req;
        int32_t ron = G.rec_on;
        memcpy(path, G.rec_path, sizeof(path));
        ma_mutex_unlock(&G.lock);

        if (ereq != G.enum_done) {
            G.enum_done = ereq;
            do_enumerate();
        }
        if (gen != G.cur_gen) {
            apply(&want);
            G.cur_gen = gen;
        }
        check_lost();
        if (rgen != G.cur_rec_gen) {
            G.cur_rec_gen = rgen;
            if (ron) rec_start(path);
            else rec_stop(SA_REC_IDLE, SA_OK);
        }
        rec_service();
        drain_events();
        publish();
        sa_sleep_ms(G.cap_open ? 10 : 25);
    }
    close_all();
    drain_events();
    publish();
    ma_context_uninit(&G.ctx);
    if (G.backend == SA_BACKEND_SYSTEM) sa_timer_1ms(0);
}

/* ======================================================================== API */

SA_API int32_t sa_api_version(void) { return SA_API_VERSION; }
SA_API const char* sa_miniaudio_version(void) { return MA_VERSION_STRING; }
SA_API int32_t sa_sizeof_status(void) { return (int32_t)sizeof(sa_status); }
SA_API int32_t sa_sizeof_device(void) { return (int32_t)sizeof(sa_device); }
SA_API int32_t sa_sizeof_event(void) { return (int32_t)sizeof(sa_event); }

SA_API int32_t sa_init(int32_t backend) {
    if (G.inited) return SA_OK;
    memset(&G, 0, sizeof(G));
    G.backend = backend == SA_BACKEND_NULL ? SA_BACKEND_NULL : SA_BACKEND_SYSTEM;
    G.t0_us = sa_now_us64();
    sa_stf(&G.gain_bits, 0.5f);
    G.cur.period = 0;
    G.rec_bits = 0;
    if (ma_mutex_init(&G.lock) != MA_SUCCESS) return SA_ERR_NO_CONTEXT;
    G.thread = sa_thread_start(control_main, NULL);
    if (!G.thread) {
        ma_mutex_uninit(&G.lock);
        return SA_ERR_NO_CONTEXT;
    }
    for (int i = 0; i < 10000 && sa_ld(&G.ready) == 0; i++) sa_sleep_ms(1);
    if (sa_ld(&G.ready) != 1) {
        sa_st(&G.quit, 1);
        sa_thread_join(G.thread);
        ma_mutex_uninit(&G.lock);
        memset(&G, 0, sizeof(G));
        return SA_ERR_NO_CONTEXT;
    }
    G.inited = 1;
    return SA_OK;
}

SA_API void sa_shutdown(void) {
    if (!G.inited) return;
    sa_st(&G.quit, 1);
    sa_thread_join(G.thread);
    ma_mutex_uninit(&G.lock);
    G.inited = 0;
}

SA_API void sa_enumerate(void) {
    if (!G.inited) return;
    ma_mutex_lock(&G.lock);
    G.enum_req++;
    ma_mutex_unlock(&G.lock);
}

SA_API int32_t sa_device_count(int32_t capture) {
    if (!G.inited) return 0;
    ma_mutex_lock(&G.lock);
    int32_t n = capture ? G.ncap : G.nplay;
    ma_mutex_unlock(&G.lock);
    return n;
}

SA_API int32_t sa_device_get(int32_t capture, int32_t i, sa_device* out) {
    if (!G.inited || !out) return SA_ERR_BAD_ARG;
    int32_t rc = SA_ERR_BAD_ARG;
    ma_mutex_lock(&G.lock);
    int32_t n = capture ? G.ncap : G.nplay;
    if (i >= 0 && i < n) {
        *out = capture ? G.caps[i] : G.plays[i];
        rc = SA_OK;
    }
    ma_mutex_unlock(&G.lock);
    return rc;
}

SA_API uint32_t sa_configure(int32_t run, const char* input, const char* output, int32_t period, int32_t monitor, int32_t exclusive) {
    if (!G.inited) return 0;
    if (period < 16) period = 16;
    if (period > 4096) period = 4096;
    ma_mutex_lock(&G.lock);
    G.want.run = run ? 1 : 0;
    copy_name(G.want.input, input);
    copy_name(G.want.output, output);
    G.want.period = period;
    G.want.monitor = monitor ? 1 : 0;
    G.want.exclusive = exclusive & (SA_EXCLUSIVE_INPUT | SA_EXCLUSIVE_OUTPUT);
    uint32_t gen = ++G.want_gen;
    ma_mutex_unlock(&G.lock);
    return gen;
}

SA_API void sa_set_gain(float gain) {
    if (!(gain >= 0)) gain = 0;
    if (gain > 4) gain = 4;
    sa_stf(&G.gain_bits, gain);
}

SA_API void sa_record_start(const char* path) {
    if (!G.inited || !path) return;
    size_t n = strlen(path);
    if (n >= sizeof(G.rec_path)) return;
    ma_mutex_lock(&G.lock);
    memcpy(G.rec_path, path, n + 1);
    G.rec_on = 1;
    G.rec_gen++;
    ma_mutex_unlock(&G.lock);
}

SA_API void sa_record_stop(void) {
    if (!G.inited) return;
    ma_mutex_lock(&G.lock);
    G.rec_on = 0;
    G.rec_gen++;
    ma_mutex_unlock(&G.lock);
}

SA_API void sa_get_status(sa_status* out) {
    if (!out) return;
    if (!G.inited) {
        memset(out, 0, sizeof(*out));
        out->api_version = SA_API_VERSION;
        out->mic_permission = sa_mic_status();
        return;
    }
    ma_mutex_lock(&G.lock);
    *out = G.st;
    ma_mutex_unlock(&G.lock);
    out->level_l = sa_ldf(&G.lvl_l);
    out->level_r = sa_ldf(&G.lvl_r);
    out->capture_callbacks = sa_ld(&G.cap_callbacks);
    out->playback_callbacks = sa_ld(&G.play_callbacks);
    out->gain = sa_ldf(&G.gain_bits);
    uint64_t now = sa_now_us64() - G.t0_us;
    out->now_lo = (uint32_t)now;
    out->now_hi = (uint32_t)(now >> 32);
}

SA_API int32_t sa_get_events(uint32_t after_seq, sa_event* out, int32_t max) {
    if (!G.inited || !out || max <= 0) return 0;
    int32_t n = 0;
    ma_mutex_lock(&G.lock);
    uint32_t newest = G.ev_seq;
    uint32_t oldest = newest > SA_EVLOG ? newest - SA_EVLOG + 1 : 1;
    uint32_t from = after_seq + 1 > oldest ? after_seq + 1 : oldest;
    for (uint32_t s = from; s <= newest && n < max; s++) out[n++] = G.evlog[(s - 1) % SA_EVLOG];
    ma_mutex_unlock(&G.lock);
    return n;
}

SA_API void sa_test_jitter(int32_t max_late_us, int32_t every_n, int32_t output) {
    sa_st(&G.jit_us, max_late_us > 0 ? (uint32_t)max_late_us : 0u);
    sa_st(&G.jit_every, every_n > 0 ? (uint32_t)every_n : 0u);
    sa_st(&G.jit_out, output ? 1u : 0u);
}

SA_API int32_t sa_documents_dir(char* out, int32_t size) {
    if (!out || size <= 0) return 0;
    return sa_documents_dir_impl(out, size);
}

SA_API void sa_request_mic(void) { sa_mic_request(); }

/* the self-test reaches into the state above (null-backend session) */
int sa_internal_inited(void) { return G.inited; }
