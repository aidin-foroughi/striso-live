/* striso_midi: MIDI input to one sink (see striso_midi.h).
 *
 * Locks (both static, so nothing needs sa_midi_init to exist):
 *   table    the device table, the list, the system's handles; held while opening and closing
 *            inputs (WinMM's midiInClose waits for its callbacks, which never take this lock).
 *   deliver  everything a message touches: each device's parser, counters and live flag, the
 *            sink, the monitor ring. The driver's callback takes only this one, for one batch.
 * Order: table, then deliver. A system call that waits for callbacks (midiInStop/Reset/Close,
 * MIDIPortDisconnectSource) is never made with deliver held.
 *
 * Each open carries a session number (in WinMM's dwInstance, CoreMIDI's connection refCon, with
 * the slot): a late callback of an earlier connection is ignored under the deliver lock.
 */
#include "striso_midi.h"
#include "sa_midi_internal.h"
#include "sa_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#  include <mmsystem.h>
typedef SRWLOCK sa_lk;
#  define SA_LK_INIT SRWLOCK_INIT
static void lk(sa_lk* l) { AcquireSRWLockExclusive(l); }
static void ulk(sa_lk* l) { ReleaseSRWLockExclusive(l); }
#else
#  include <pthread.h>
typedef pthread_mutex_t sa_lk;
#  define SA_LK_INIT PTHREAD_MUTEX_INITIALIZER
static void lk(sa_lk* l) { pthread_mutex_lock(l); }
static void ulk(sa_lk* l) { pthread_mutex_unlock(l); }
#endif

#if defined(__APPLE__)
#  include <CoreFoundation/CoreFoundation.h>
#  include <CoreMIDI/CoreMIDI.h>
#endif

/* ======================================================================== the parser */

void sa_midi_parser_reset(sa_midi_parser* p) { memset(p, 0, sizeof(*p)); }

int sa_midi_parse(sa_midi_parser* p, const uint8_t* in, int n, uint8_t* out, int max_packets, int* used) {
    int k = 0, i = 0;
    for (; i < n; i++) {
        const uint8_t b = in[i];
        if (b >= 0xF8) continue; /* real time (clock, start, stop, active sensing, reset): dropped, the state untouched */
        if (b & 0x80) {
            p->have = 0;
            p->skip = 0;
            p->sysex = 0;
            if (b < 0xF0) {
                p->status = b;
                p->need = (b & 0xF0) == 0xC0 || (b & 0xF0) == 0xD0 ? 1 : 2;
            } else {
                p->status = 0; /* system common cancels running status */
                if (b == 0xF0) p->sysex = 1;
                else if (b == 0xF1 || b == 0xF3) p->skip = 1;
                else if (b == 0xF2) p->skip = 2;
            }
            continue;
        }
        if (p->sysex) continue;
        if (p->skip) {
            p->skip--;
            continue;
        }
        if (!p->status) continue; /* data without a status: dropped */
        p->data[p->have++] = b;
        if (p->have < p->need) continue;
        if (k >= max_packets) {
            p->have--; /* keep this byte for the next call */
            break;
        }
        uint8_t* o = out + 4 * k++;
        o[0] = (uint8_t)(p->status >> 4); /* cable 0, CIN = the status nibble */
        o[1] = p->status;
        o[2] = p->data[0];
        o[3] = p->need == 2 ? p->data[1] : 0;
        p->have = 0;
    }
    if (used) *used = i;
    return k;
}

/* ======================================================================== state */

typedef struct {
    int used;
    char id[256], name[256];
    int present, listed, gone, open, is_virtual;
    int32_t error, os_error;
    uint64_t seen; /* the refresh that saw it last (slot reuse: the oldest goes first) */
    /* under the deliver lock */
    int live;
    uint32_t session;
    uint32_t messages;
    int64_t last_us;
    sa_midi_parser parser;
#if defined(_WIN32)
    UINT index;
    HMIDIIN h;
#elif defined(__APPLE__)
    MIDIEndpointRef src;
#endif
} mdev;

typedef struct {
    char id[256], name[256];
#if defined(_WIN32)
    UINT index;
#elif defined(__APPLE__)
    MIDIEndpointRef src;
#endif
} osdev;

static sa_lk g_table = SA_LK_INIT, g_deliver = SA_LK_INIT, g_test = SA_LK_INIT;

static struct {
    int inited;
    mdev dev[SA_MIDI_MAX];
    int order[SA_MIDI_MAX], norder;
    uint32_t gen;
    uint64_t refreshes;
    osdev os[SA_MIDI_MAX]; /* scratch of one enumeration */
    /* deliver lock */
    sa_midi_sink_fn sink;
    void* sink_user;
    sa_midi_event ring[SA_MIDI_RING];
    uint32_t rw, rr, lost;
#if defined(__APPLE__)
    MIDIClientRef client;
    MIDIPortRef port;
    sa_thread thread;
    CFRunLoopRef rl;
    volatile uint32_t ready, quit, changes;
    OSStatus status;
#endif
} M;

static int64_t now_us(void) { return (int64_t)sa_now_us64(); }

static void copy_str(char* dst, const char* src, size_t size) {
    size_t n = strlen(src);
    if (n >= size) n = size - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

static void* refcon(int slot, uint32_t session) { return (void*)(uintptr_t)(((uintptr_t)session << 8) | (uintptr_t)slot); }

/* ======================================================================== delivery */

static void ring_push(int slot, const uint8_t* pk, int64_t t) {
    if (M.rw - M.rr >= SA_MIDI_RING) {
        M.lost++;
        return;
    }
    sa_midi_event* e = &M.ring[M.rw % SA_MIDI_RING];
    e->t_us = t;
    e->device = slot;
    e->len = (uint8_t)(pk[0] == 0xC || pk[0] == 0xD ? 2 : 3);
    e->bytes[0] = pk[1];
    e->bytes[1] = pk[2];
    e->bytes[2] = pk[3];
    M.rw++;
}

/* bytes of one input (slot, session) through its parser to the sink and the monitor */
static int deliver(int slot, uint32_t session, const uint8_t* bytes, int n, int64_t t) {
    if (slot < 0 || slot >= SA_MIDI_MAX) return 0;
    uint8_t pk[64 * 4];
    int total = 0;
    lk(&g_deliver);
    mdev* d = &M.dev[slot];
    if (d->live && d->session == session) {
        while (n > 0) {
            int used = 0;
            const int k = sa_midi_parse(&d->parser, bytes, n, pk, 64, &used);
            bytes += used;
            n -= used;
            if (k == 0) break;
            for (int j = 0; j < k; j++) ring_push(slot, pk + 4 * j, t);
            d->messages += (uint32_t)k;
            d->last_us = t;
            total += k;
            if (M.sink) M.sink(M.sink_user, pk, 4 * k);
        }
    }
    ulk(&g_deliver);
    return total;
}

static void set_live(mdev* d, int live) {
    lk(&g_deliver);
    if (live) {
        d->session++;
        sa_midi_parser_reset(&d->parser);
    }
    d->live = live;
    ulk(&g_deliver);
}

/* ======================================================================== the system: WinMM */
#if defined(_WIN32)

static void CALLBACK winmm_cb(HMIDIIN h, UINT msg, DWORD_PTR inst, DWORD_PTR p1, DWORD_PTR p2) {
    (void)h;
    (void)p2;
    if (msg != MIM_DATA && msg != MIM_MOREDATA) return; /* MIM_LONGDATA never comes: no SysEx buffers are given */
    const int64_t t = now_us();
    const uint8_t st = (uint8_t)(p1 & 0xFF);
    uint8_t b[3] = {st, (uint8_t)((p1 >> 8) & 0x7F), (uint8_t)((p1 >> 16) & 0x7F)};
    /* WinMM expands running status: every short message carries its status */
    int len = 1;
    if (st >= 0x80 && st < 0xF0) len = (st & 0xF0) == 0xC0 || (st & 0xF0) == 0xD0 ? 2 : 3;
    else if (st == 0xF1 || st == 0xF3) len = 2;
    else if (st == 0xF2) len = 3;
    deliver((int)(inst & 0xFF), (uint32_t)(inst >> 8), b, len, t);
}

static int os_enumerate(osdev* out, int max) {
    UINT n = midiInGetNumDevs();
    int k = 0;
    for (UINT i = 0; i < n && k < max; i++) {
        MIDIINCAPSW caps;
        memset(&caps, 0, sizeof(caps));
        if (midiInGetDevCapsW(i, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
        char name[256];
        int w = WideCharToMultiByte(CP_UTF8, 0, caps.szPname, -1, name, (int)sizeof(name), NULL, NULL);
        if (w <= 0) copy_str(name, "MIDI input", sizeof(name));
        /* the name, then "#2", "#3" for the same name again, in enumeration order */
        int dup = 1;
        for (int j = 0; j < k; j++)
            if (strcmp(out[j].name, name) == 0) dup++;
        copy_str(out[k].name, name, sizeof(out[k].name));
        if (dup == 1) copy_str(out[k].id, name, sizeof(out[k].id));
        else snprintf(out[k].id, sizeof(out[k].id), "%s#%d", name, dup);
        out[k].index = i;
        k++;
    }
    return k;
}

static void os_take(mdev* d, const osdev* o) { d->index = o->index; }

static int32_t os_open(mdev* d, int slot) {
    HMIDIIN h = NULL;
    MMRESULT r = midiInOpen(&h, d->index, (DWORD_PTR)winmm_cb, (DWORD_PTR)refcon(slot, d->session), CALLBACK_FUNCTION);
    d->os_error = (int32_t)r;
    if (r == MMSYSERR_ALLOCATED) return SA_ERR_MIDI_IN_USE;
    if (r != MMSYSERR_NOERROR) return r == MMSYSERR_BADDEVICEID || r == MMSYSERR_NODRIVER ? SA_ERR_NOT_FOUND : SA_ERR_MIDI_OPEN;
    r = midiInStart(h);
    if (r != MMSYSERR_NOERROR) {
        d->os_error = (int32_t)r;
        midiInClose(h);
        return SA_ERR_MIDI_OPEN;
    }
    d->h = h;
    d->os_error = 0;
    return SA_OK;
}

static void os_close(mdev* d) {
    if (!d->h) return;
    midiInStop(d->h);
    midiInReset(d->h);
    midiInClose(d->h); /* returns once no callback of it runs */
    d->h = NULL;
}

static int32_t os_init(void) { return SA_OK; }
static void os_shutdown(void) {}

/* ======================================================================== the system: CoreMIDI */
#elif defined(__APPLE__)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void mac_read(const MIDIPacketList* pl, void* port_ref, void* conn_ref) {
    (void)port_ref;
    const uintptr_t rc = (uintptr_t)conn_ref;
    const int slot = (int)(rc & 0xFF);
    const uint32_t session = (uint32_t)(rc >> 8);
    /* the packet list in one pass (one sink call), batched up to 1 KB; a message may span packets */
    uint8_t buf[1024];
    int n = 0;
    int64_t t = 0;
    const MIDIPacket* p = &pl->packet[0];
    for (UInt32 i = 0; i < pl->numPackets; i++) {
        if (!t) t = p->timeStamp ? (int64_t)sa_device_time_us((uint64_t)p->timeStamp) : now_us();
        const int len = (int)p->length;
        for (int j = 0; j < len;) {
            int c = len - j;
            if (c > (int)sizeof(buf) - n) c = (int)sizeof(buf) - n;
            memcpy(buf + n, p->data + j, (size_t)c);
            n += c;
            j += c;
            if (n == (int)sizeof(buf)) {
                deliver(slot, session, buf, n, t);
                n = 0;
            }
        }
        p = MIDIPacketNext(p);
    }
    if (n) deliver(slot, session, buf, n, t ? t : now_us());
}

#pragma clang diagnostic pop

static void mac_notify(const MIDINotification* m, void* ref) {
    (void)m;
    (void)ref;
    __atomic_add_fetch(&M.changes, 1u, __ATOMIC_ACQ_REL);
}

static void mac_timer(CFRunLoopTimerRef t, void* info) {
    (void)t;
    (void)info;
}

/* the client lives on this thread's run loop: CoreMIDI keeps the client's view of the system
 * (the source list) current through it, whatever thread the caller is on */
static void mac_thread(void* arg) {
    (void)arg;
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    CFRetain(rl);
    M.rl = rl;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus s = MIDIClientCreate(CFSTR("Striso Live"), mac_notify, NULL, &M.client);
    if (s == noErr) s = MIDIInputPortCreate(M.client, CFSTR("Striso Live input"), mac_read, NULL, &M.port);
#pragma clang diagnostic pop
    M.status = s;
    CFRunLoopTimerRef keep = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1e7, 1e7, 0, 0, mac_timer, NULL);
    CFRunLoopAddTimer(rl, keep, kCFRunLoopDefaultMode);
    __atomic_store_n(&M.ready, s == noErr ? 1u : 2u, __ATOMIC_RELEASE);
    while (s == noErr && !__atomic_load_n(&M.quit, __ATOMIC_ACQUIRE)) {
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false) == kCFRunLoopRunFinished) sa_sleep_ms(50);
    }
    if (M.port) MIDIPortDispose(M.port);
    if (M.client) MIDIClientDispose(M.client);
    M.port = 0;
    M.client = 0;
    CFRunLoopRemoveTimer(rl, keep, kCFRunLoopDefaultMode);
    CFRelease(keep);
    M.rl = NULL;
    CFRelease(rl);
}

static int32_t os_init(void) {
    M.ready = 0;
    M.quit = 0;
    M.thread = sa_thread_start(mac_thread, NULL);
    if (!M.thread) return SA_ERR_MIDI_SYSTEM;
    for (int i = 0; i < 5000 && !__atomic_load_n(&M.ready, __ATOMIC_ACQUIRE); i++) sa_sleep_ms(1);
    if (__atomic_load_n(&M.ready, __ATOMIC_ACQUIRE) != 1) {
        __atomic_store_n(&M.quit, 1u, __ATOMIC_RELEASE);
        sa_thread_join(M.thread);
        M.thread = NULL;
        return SA_ERR_MIDI_SYSTEM;
    }
    return SA_OK;
}

static void os_shutdown(void) {
    if (!M.thread) return;
    __atomic_store_n(&M.quit, 1u, __ATOMIC_RELEASE);
    if (M.rl) CFRunLoopStop(M.rl);
    sa_thread_join(M.thread);
    M.thread = NULL;
}

static void cfstr_utf8(CFStringRef s, char* out, int size) {
    out[0] = 0;
    if (s && !CFStringGetCString(s, out, size, kCFStringEncodingUTF8)) out[0] = 0;
}

static int os_enumerate(osdev* out, int max) {
    if (!M.client) return 0;
    const ItemCount n = MIDIGetNumberOfSources();
    int k = 0;
    for (ItemCount i = 0; i < n && k < max; i++) {
        MIDIEndpointRef e = MIDIGetSource(i);
        if (!e) continue;
        SInt32 offline = 0, uid = 0;
        if (MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &offline) == noErr && offline) continue;
        if (MIDIObjectGetIntegerProperty(e, kMIDIPropertyUniqueID, &uid) != noErr) continue;
        CFStringRef nm = NULL;
        out[k].name[0] = 0;
        if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &nm) == noErr && nm) {
            cfstr_utf8(nm, out[k].name, (int)sizeof(out[k].name));
            CFRelease(nm);
        }
        if (!out[k].name[0] && MIDIObjectGetStringProperty(e, kMIDIPropertyName, &nm) == noErr && nm) {
            cfstr_utf8(nm, out[k].name, (int)sizeof(out[k].name));
            CFRelease(nm);
        }
        if (!out[k].name[0]) copy_str(out[k].name, "MIDI source", sizeof(out[k].name));
        snprintf(out[k].id, sizeof(out[k].id), "%d", (int)uid);
        out[k].src = e;
        k++;
    }
    return k;
}

static void os_take(mdev* d, const osdev* o) { d->src = o->src; }

static int32_t os_open(mdev* d, int slot) {
    OSStatus s = MIDIPortConnectSource(M.port, d->src, refcon(slot, d->session));
    d->os_error = (int32_t)s;
    if (s == kMIDIObjectNotFound) return SA_ERR_NOT_FOUND;
    return s == noErr ? SA_OK : SA_ERR_MIDI_OPEN;
}

static void os_close(mdev* d) {
    if (M.port && d->src) MIDIPortDisconnectSource(M.port, d->src); /* a stale ref (unplugged) just fails */
}

/* ======================================================================== no system MIDI */
#else

static int os_enumerate(osdev* out, int max) {
    (void)out;
    (void)max;
    return 0;
}
static void os_take(mdev* d, const osdev* o) {
    (void)d;
    (void)o;
}
static int32_t os_open(mdev* d, int slot) {
    (void)d;
    (void)slot;
    return SA_ERR_NOT_FOUND;
}
static void os_close(mdev* d) { (void)d; }
static int32_t os_init(void) { return SA_OK; }
static void os_shutdown(void) {}

#endif

/* ======================================================================== the table (table lock) */

static int find(const char* id) {
    for (int i = 0; i < SA_MIDI_MAX; i++)
        if (M.dev[i].used && strcmp(M.dev[i].id, id) == 0) return i;
    return -1;
}

/* a slot for a new id: a free one, else the one longest unseen that is not listed nor open */
static int alloc_slot(const char* id) {
    int best = -1;
    for (int i = 0; i < SA_MIDI_MAX; i++) {
        mdev* d = &M.dev[i];
        if (!d->used) {
            best = i;
            break;
        }
        if (!d->listed && !d->open && !d->is_virtual && (best < 0 || d->seen < M.dev[best].seen)) best = i;
    }
    if (best < 0) return -1;
    mdev* d = &M.dev[best];
    lk(&g_deliver);
    const uint32_t session = d->session; /* sessions keep counting: a late callback never matches */
    memset(d, 0, sizeof(*d));
    d->session = session;
    ulk(&g_deliver);
    d->used = 1;
    copy_str(d->id, id, sizeof(d->id));
    return best;
}

static void close_dev(mdev* d) {
    if (!d->open) return;
    set_live(d, 0); /* nothing reaches the sink from here on */
    if (!d->is_virtual) os_close(d);
    d->open = 0;
}

static void forget(int slot) {
    mdev* d = &M.dev[slot];
    close_dev(d);
    set_live(d, 0);
    d->used = 0;
    d->listed = 0;
    d->present = 0;
    d->gone = 0;
}

/* the system's inputs now; returns 1 when the list changed */
static int refresh_locked(void) {
    int old[SA_MIDI_MAX], nold = M.norder;
    memcpy(old, M.order, sizeof(old));
    int changed = 0;
    const int n = M.inited ? os_enumerate(M.os, SA_MIDI_MAX) : 0;
    M.refreshes++;
    int was[SA_MIDI_MAX];
    for (int i = 0; i < SA_MIDI_MAX; i++) {
        was[i] = M.dev[i].present;
        if (M.dev[i].used && !M.dev[i].is_virtual) M.dev[i].present = 0;
    }
    int order[SA_MIDI_MAX], k = 0;
    for (int j = 0; j < n; j++) {
        int s = find(M.os[j].id);
        if (s >= 0 && M.dev[s].is_virtual) continue; /* the system's id wins only when no virtual one has it */
        if (s < 0) s = alloc_slot(M.os[j].id);
        if (s < 0) continue;
        mdev* d = &M.dev[s];
        if (strcmp(d->name, M.os[j].name) != 0) {
            copy_str(d->name, M.os[j].name, sizeof(d->name));
            changed = 1;
        }
        d->present = 1;
        d->seen = M.refreshes;
        if (!d->open) os_take(d, &M.os[j]);
        order[k++] = s;
    }
    for (int i = 0; i < SA_MIDI_MAX; i++) {
        mdev* d = &M.dev[i];
        if (!d->used || d->is_virtual) continue;
        if (!d->present && d->open) {
            close_dev(d); /* unplugged while open */
            d->error = SA_ERR_MIDI_GONE;
            d->gone = 1;
        }
        if (d->present != was[i]) changed = 1;
    }
    for (int i = 0; i < SA_MIDI_MAX; i++)
        if (M.dev[i].used && !M.dev[i].is_virtual && !M.dev[i].present && M.dev[i].gone) order[k++] = i;
    for (int i = 0; i < SA_MIDI_MAX; i++)
        if (M.dev[i].used && M.dev[i].is_virtual) order[k++] = i;
    for (int i = 0; i < SA_MIDI_MAX; i++) M.dev[i].listed = 0;
    for (int i = 0; i < k; i++) M.dev[order[i]].listed = 1;
    if (k != nold || memcmp(order, old, sizeof(int) * (size_t)k) != 0) changed = 1;
    memcpy(M.order, order, sizeof(order));
    M.norder = k;
    if (changed) M.gen++;
    return changed;
}

/* ======================================================================== API */

SA_API int32_t sa_midi_api_version(void) { return SA_MIDI_API_VERSION; }
SA_API int32_t sa_midi_sizeof_device(void) { return (int32_t)sizeof(sa_midi_device); }
SA_API int32_t sa_midi_sizeof_event(void) { return (int32_t)sizeof(sa_midi_event); }

SA_API int32_t sa_midi_init(void) {
    lk(&g_table);
    int32_t r = SA_OK;
    if (!M.inited) {
        r = os_init();
        if (r == SA_OK) {
            M.inited = 1;
            refresh_locked();
        }
    }
    ulk(&g_table);
    return r;
}

SA_API void sa_midi_shutdown(void) {
    lk(&g_table);
    for (int i = 0; i < SA_MIDI_MAX; i++)
        if (M.dev[i].used) forget(i);
    M.norder = 0;
    M.gen++;
    lk(&g_deliver);
    M.sink = NULL;
    M.sink_user = NULL;
    M.rr = M.rw;
    M.lost = 0;
    ulk(&g_deliver);
    if (M.inited) os_shutdown();
    M.inited = 0;
    ulk(&g_table);
}

SA_API uint32_t sa_midi_refresh(void) {
    lk(&g_table);
    if (M.inited) refresh_locked();
    const uint32_t g = M.gen;
    ulk(&g_table);
    return g;
}

SA_API int32_t sa_midi_count(void) {
    lk(&g_table);
    const int32_t n = M.norder;
    ulk(&g_table);
    return n;
}

SA_API int32_t sa_midi_get(int32_t i, sa_midi_device* out) {
    if (!out) return SA_ERR_BAD_ARG;
    lk(&g_table);
    if (i < 0 || i >= M.norder) {
        ulk(&g_table);
        return SA_ERR_BAD_ARG;
    }
    const int s = M.order[i];
    const mdev* d = &M.dev[s];
    memset(out, 0, sizeof(*out));
    copy_str(out->name, d->name[0] ? d->name : d->id, sizeof(out->name));
    copy_str(out->id, d->id, sizeof(out->id));
    out->open = d->open;
    out->error = d->error;
    out->slot = s;
    out->present = d->present;
    out->is_virtual = d->is_virtual;
    out->os_error = d->os_error;
    lk(&g_deliver);
    out->messages = d->messages;
    out->last_us = d->last_us;
    ulk(&g_deliver);
    ulk(&g_table);
    return SA_OK;
}

SA_API int32_t sa_midi_open(const char* id) {
    if (!id) return SA_ERR_BAD_ARG;
    lk(&g_table);
    int s = find(id);
    if (s >= 0 && M.dev[s].is_virtual) {
        ulk(&g_table);
        return SA_OK;
    }
    if (!M.inited) {
        ulk(&g_table);
        return SA_ERR_NOT_INITIALISED;
    }
    refresh_locked();
    s = find(id);
    if (s < 0 || !M.dev[s].present) {
        ulk(&g_table);
        return SA_ERR_NOT_FOUND;
    }
    mdev* d = &M.dev[s];
    if (d->open) {
        ulk(&g_table);
        return SA_OK;
    }
    set_live(d, 1); /* before the system starts it: the first message is not lost */
    const int32_t r = os_open(d, s);
    if (r == SA_OK) {
        d->open = 1;
        d->error = SA_OK;
        d->gone = 0;
    } else {
        set_live(d, 0);
        d->error = r;
    }
    ulk(&g_table);
    return r;
}

SA_API int32_t sa_midi_close(const char* id) {
    if (!id) return SA_ERR_BAD_ARG;
    lk(&g_table);
    const int s = find(id);
    if (s < 0 || !M.dev[s].listed) {
        ulk(&g_table);
        return SA_ERR_NOT_FOUND;
    }
    mdev* d = &M.dev[s];
    if (d->is_virtual || !d->present) {
        forget(s);
        refresh_locked();
    } else {
        close_dev(d);
        d->error = SA_OK;
        d->os_error = 0;
        d->gone = 0;
    }
    ulk(&g_table);
    return SA_OK;
}

SA_API void sa_midi_close_all(void) {
    lk(&g_table);
    for (int i = 0; i < SA_MIDI_MAX; i++) {
        mdev* d = &M.dev[i];
        if (!d->used) continue;
        if (d->is_virtual || (!d->present && d->gone)) forget(i);
        else {
            close_dev(d);
            d->error = SA_OK;
            d->os_error = 0;
            d->gone = 0;
        }
    }
    refresh_locked();
    ulk(&g_table);
}

SA_API void sa_midi_set_sink(sa_midi_sink_fn fn, void* user) {
    lk(&g_deliver); /* every sink call holds it: none is running once we have it */
    M.sink = fn;
    M.sink_user = fn ? user : NULL;
    ulk(&g_deliver);
}

SA_API int32_t sa_midi_inject(const char* id, const uint8_t* bytes, int32_t n) {
    if (!id || !id[0] || (n > 0 && !bytes) || n < 0) return SA_ERR_BAD_ARG;
    lk(&g_table);
    int s = find(id);
    if (s < 0 || (!M.dev[s].is_virtual && !M.dev[s].present && !M.dev[s].open && !M.dev[s].listed)) {
        if (s < 0) s = alloc_slot(id);
        if (s < 0) {
            ulk(&g_table);
            return SA_ERR_MIDI_FULL;
        }
        mdev* d = &M.dev[s];
        d->is_virtual = 1;
        d->present = 1;
        d->open = 1;
        copy_str(d->name, id, sizeof(d->name));
        set_live(d, 1);
        refresh_locked(); /* lists it: the generation goes up */
    }
    const int live = M.dev[s].open;
    const uint32_t session = M.dev[s].session;
    ulk(&g_table);
    if (!live) return 0;
    return deliver(s, session, bytes, n, now_us());
}

SA_API int32_t sa_midi_events(sa_midi_event* out, int32_t max) {
    if (!out || max <= 0) return 0;
    int32_t k = 0;
    lk(&g_deliver);
    while (k < max && M.rr != M.rw) out[k++] = M.ring[M.rr++ % SA_MIDI_RING];
    ulk(&g_deliver);
    return k;
}

SA_API uint32_t sa_midi_events_lost(void) {
    lk(&g_deliver);
    const uint32_t n = M.lost;
    ulk(&g_deliver);
    return n;
}

/* ---- the test sink */

#define SA_TEST_SINK 65536
static uint8_t g_tbuf[SA_TEST_SINK];
static int g_tlen;

SA_API int32_t sa_midi_test_sink(void* user, const uint8_t* packets, int32_t n) {
    (void)user;
    lk(&g_test);
    int c = n;
    if (c > SA_TEST_SINK - g_tlen) c = SA_TEST_SINK - g_tlen;
    if (c > 0) {
        memcpy(g_tbuf + g_tlen, packets, (size_t)c);
        g_tlen += c;
    }
    ulk(&g_test);
    return n;
}

SA_API int32_t sa_midi_test_sink_read(uint8_t* out, int32_t max) {
    if (!out || max <= 0) return 0;
    lk(&g_test);
    int c = g_tlen < max ? g_tlen : max;
    memcpy(out, g_tbuf, (size_t)c);
    memmove(g_tbuf, g_tbuf + c, (size_t)(g_tlen - c));
    g_tlen -= c;
    ulk(&g_test);
    return c;
}

int sa_midi_internal_inited(void) {
    lk(&g_table);
    const int r = M.inited;
    ulk(&g_table);
    return r;
}

int sa_midi_internal_has_sink(void) {
    lk(&g_deliver);
    const int r = M.sink != NULL;
    ulk(&g_deliver);
    return r;
}
