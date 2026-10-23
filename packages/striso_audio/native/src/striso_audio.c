/* striso_audio: the Striso's USB audio input through the computer (see striso_audio.h).
 *
 * Threads:
 *   control thread (this file)  owns the miniaudio context and the devices: applies the wanted
 *       state (sa_configure), enumerates, notices lost devices, writes the WAV file, publishes the
 *       status. Initialises COM for WASAPI on itself.
 *   capture callback            meters, pushes into the passthrough ring and the recording ring
 *   playback callback           pulls from the passthrough (resampler + drift servo + gain)
 * The callbacks never lock, allocate or touch the disk. The caller's threads only take the
 * request lock for a few copies.
 */
#include "striso_audio.h"
#include "sa_core.h"
#include "sa_platform.h"

#include <ctype.h>
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

typedef struct {
    char input[SA_NAME], output[SA_NAME];
    int32_t run, period, monitor, exclusive;
} sa_want;

static struct {
    int inited;
    int32_t backend;
    ma_context ctx;
    ma_mutex lock; /* requests, device lists, published status */
    sa_thread thread;
    volatile uint32_t quit;
    volatile uint32_t ready; /* 1: context up, 2: failed */

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

    /* shared with the audio callbacks */
    void* volatile pass; /* sa_pass* */
    void* volatile rec;  /* sa_ring* */
    volatile uint32_t cb_enter, cb_exit;
    volatile uint32_t cap_closing, play_closing, cap_lost_evt, play_lost_evt;
    volatile uint32_t cap_callbacks, play_callbacks;
    volatile uint32_t gain_bits, lvl_l, lvl_r, rec_dropped;
    float peak_l, peak_r; /* capture callback's meter state */

    /* published (under lock) */
    sa_status st;
    sa_device caps[SA_MAXDEV], plays[SA_MAXDEV];
    int ncap, nplay;
    volatile uint32_t devices_gen;
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

/* waits until a capture callback that may hold an old pointer has returned */
static int quiesce_capture(void) {
    uint32_t e = sa_ld(&G.cb_enter);
    for (int i = 0; i < 500; i++) {
        if ((int32_t)(sa_ld(&G.cb_exit) - e) >= 0) return 1;
        sa_sleep_ms(1);
    }
    return 0;
}

/* ======================================================================== callbacks */

static void capture_cb(ma_device* d, void* out, const void* in, ma_uint32 n) {
    (void)out;
    sa_inc(&G.cb_enter);
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
            d->is_default = pc[i].isDefault ? 1 : 0;
            d->is_striso = is_striso(&pc[i]);
            ma_device_info full;
            if (ma_context_get_device_info(&G.ctx, ma_device_type_capture, &pc[i].id, &full) == MA_SUCCESS)
                native_format(&full, &d->native_bits, &d->native_rate, &d->native_channels);
        }
        for (ma_uint32 i = 0; i < cp && np < SA_MAXDEV; i++) {
            sa_device* d = &plays[np++];
            memset(d, 0, sizeof(*d));
            copy_name(d->name, pp[i].name);
            d->is_default = pp[i].isDefault ? 1 : 0;
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

static void close_playback(int32_t state, int32_t err) {
    if (G.play_open) {
        sa_st(&G.play_closing, 1);
        ma_device_uninit(&G.play); /* joins its thread: no playback callback after this */
        sa_st(&G.play_closing, 0);
        G.play_open = 0;
    }
    sa_st(&G.play_lost_evt, 0);
    sa_pass* p = G.pass_owned;
    if (p) {
        sa_stp(&G.pass, NULL);
        if (quiesce_capture()) {
            sa_pass_free(p);
            free(p);
        } /* else leaked on purpose: the capture thread may still hold it */
        G.pass_owned = NULL;
    }
    G.play_state = state;
    G.play_error = err;
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
    sa_stf(&G.lvl_l, 0);
    sa_stf(&G.lvl_r, 0);
    G.peak_l = G.peak_r = 0;
    G.cap_state = state;
    G.cap_error = err;
}

static ma_result init_capture(const ma_device_id* id, ma_share_mode mode) {
    ma_device_config c = ma_device_config_init(ma_device_type_capture);
    c.capture.pDeviceID = id;
    c.capture.format = ma_format_f32;
    c.capture.channels = 2;
    c.capture.shareMode = mode;
    c.sampleRate = 48000;
    c.periodSizeInFrames = (ma_uint32)G.cur.period;
    c.performanceProfile = ma_performance_profile_low_latency;
    c.dataCallback = capture_cb;
    c.notificationCallback = notify_cb;
    c.wasapi.usage = ma_wasapi_usage_pro_audio;
    return ma_device_init(&G.ctx, &c, &G.cap);
}

static void open_capture(void) {
    ma_device_id id;
    ma_device_info info;
    G.cap_result = 0;
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
    ma_result r = MA_ERROR;
    int tried_exclusive = 0;
#if defined(_WIN32)
    if ((G.cur.exclusive & SA_EXCLUSIVE_INPUT) && G.backend == SA_BACKEND_SYSTEM) {
        tried_exclusive = 1;
        r = init_capture(&id, ma_share_mode_exclusive);
    }
#endif
    if (r != MA_SUCCESS) r = init_capture(&id, ma_share_mode_shared);
    (void)tried_exclusive;
    if (r != MA_SUCCESS) {
        G.cap_state = SA_DEV_FAILED;
        G.cap_error = SA_ERR_OPEN_CAPTURE;
        G.cap_result = r;
        return;
    }
    G.cap_open = 1;
    sa_st(&G.cap_lost_evt, 0);
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
}

static void open_playback(void) {
    ma_device_id id;
    ma_device_info info;
    G.play_result = 0;
    ma_device_config c = ma_device_config_init(ma_device_type_playback);
    if (G.cur.output[0]) {
        if (!find_device(ma_device_type_playback, G.cur.output, &id, &info)) {
            G.play_state = SA_DEV_FAILED;
            G.play_error = SA_ERR_NOT_FOUND;
            return;
        }
        c.playback.pDeviceID = &id;
    }
    c.playback.format = ma_format_f32;
    c.playback.channels = 2;
    c.playback.shareMode = ma_share_mode_shared;
    c.sampleRate = 0; /* the device's own: the resampler bridges */
    c.periodSizeInFrames = (ma_uint32)G.cur.period;
    c.performanceProfile = ma_performance_profile_low_latency;
    c.noPreSilencedOutputBuffer = MA_TRUE;
    c.noClip = MA_TRUE;
    c.dataCallback = playback_cb;
    c.notificationCallback = notify_cb;
    c.wasapi.usage = ma_wasapi_usage_pro_audio;
    ma_result r = MA_ERROR;
#if defined(_WIN32)
    if ((G.cur.exclusive & SA_EXCLUSIVE_OUTPUT) && G.backend == SA_BACKEND_SYSTEM) {
        c.playback.shareMode = ma_share_mode_exclusive; /* the device's own format and rate */
        r = ma_device_init(&G.ctx, &c, &G.play);
        c.playback.shareMode = ma_share_mode_shared;
    }
#endif
    if (r != MA_SUCCESS) r = ma_device_init(&G.ctx, &c, &G.play);
    if (r != MA_SUCCESS) {
        G.play_state = SA_DEV_FAILED;
        G.play_error = SA_ERR_OPEN_PLAYBACK;
        G.play_result = r;
        return;
    }
    G.play_open = 1;
    sa_pass* p = (sa_pass*)malloc(sizeof(sa_pass));
    if (!p || sa_pass_init(p, (double)G.cap.sampleRate, (double)G.play.sampleRate, G.cap.capture.internalPeriodSizeInFrames) != 0) {
        free(p);
        close_playback(SA_DEV_FAILED, SA_ERR_OPEN_PLAYBACK);
        return;
    }
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
    if (G.cap_open) {
        s.capture_rate = (int32_t)G.cap.sampleRate;
        s.capture_channels = (int32_t)G.cap.capture.internalChannels;
        s.capture_period = (int32_t)G.cap.capture.internalPeriodSizeInFrames;
        s.capture_exclusive = G.cap.capture.shareMode == ma_share_mode_exclusive;
        s.capture_bits = bits_of(G.cap.capture.internalFormat);
    }
    s.capture_callbacks = sa_ld(&G.cap_callbacks);
    s.playback_state = G.play_state;
    s.playback_error = G.play_error;
    s.playback_result = G.play_result;
    if (G.play_open) {
        s.playback_rate = (int32_t)G.play.sampleRate;
        s.playback_period = (int32_t)G.play.playback.internalPeriodSizeInFrames;
        s.playback_periods = (int32_t)G.play.playback.internalPeriods;
        s.playback_exclusive = G.play.playback.shareMode == ma_share_mode_exclusive;
    }
    s.playback_callbacks = sa_ld(&G.play_callbacks);
    s.gain = sa_ldf(&G.gain_bits);
    sa_pass* p = G.pass_owned;
    if (p && G.cap_open && G.play_open) {
        double fs = p->fs_in;
        float ring = sa_ldf(&p->st_ring);
        s.ring_ms = (float)(ring / fs * 1000);
        s.target_ms = (float)(sa_ldf(&p->st_target) / fs * 1000);
        s.drift_ppm = sa_ldf(&p->st_ppm);
        s.underruns = sa_ld(&p->underruns);
        s.overruns = sa_ld(&p->overruns);
        s.resyncs = sa_ld(&p->resyncs);
        s.streaming = (int32_t)sa_ld(&p->streaming);
        s.level_out = sa_ldf(&p->st_peak);
        double in_ms = s.capture_period / fs * 1000;
        double out_ms = s.playback_rate > 0 ? (double)s.playback_period * (s.playback_periods > 0 ? s.playback_periods : 1) / s.playback_rate * 1000 : 0;
        s.latency_ms = (float)(in_ms + s.ring_ms + out_ms);
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
    ma_mutex_lock(&G.lock);
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
        publish();
        sa_sleep_ms(G.cap_open ? 10 : 25);
    }
    close_all();
    publish();
    ma_context_uninit(&G.ctx);
}

/* ======================================================================== API */

SA_API int32_t sa_api_version(void) { return SA_API_VERSION; }
SA_API const char* sa_miniaudio_version(void) { return MA_VERSION_STRING; }
SA_API int32_t sa_sizeof_status(void) { return (int32_t)sizeof(sa_status); }
SA_API int32_t sa_sizeof_device(void) { return (int32_t)sizeof(sa_device); }

SA_API int32_t sa_init(int32_t backend) {
    if (G.inited) return SA_OK;
    memset(&G, 0, sizeof(G));
    G.backend = backend == SA_BACKEND_NULL ? SA_BACKEND_NULL : SA_BACKEND_SYSTEM;
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
}

SA_API int32_t sa_documents_dir(char* out, int32_t size) {
    if (!out || size <= 0) return 0;
    return sa_documents_dir_impl(out, size);
}

SA_API void sa_request_mic(void) { sa_mic_request(); }

/* the self-test reaches into the state above (null-backend session) */
int sa_internal_inited(void) { return G.inited; }
