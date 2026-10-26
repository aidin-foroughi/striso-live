/* The operating-system bits of striso_audio: see sa_platform.h. */
#include "sa_platform.h"
#include "sa_core.h"
#include "striso_audio.h"

#include <stdlib.h>
#include <math.h>
#include <string.h>

/* ======================================================================== Windows */
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cfgmgr32.h>
#include <shlobj.h>
#include <wchar.h>

uint32_t sa_now_us(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    uint64_t f = (uint64_t)freq.QuadPart, n = (uint64_t)c.QuadPart;
    return (uint32_t)((n / f) * 1000000u + (n % f) * 1000000u / f);
}

uint64_t sa_now_us64(void) {
    static LARGE_INTEGER freq;
    LARGE_INTEGER c;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&c);
    uint64_t f = (uint64_t)freq.QuadPart, n = (uint64_t)c.QuadPart;
    return (n / f) * 1000000u + (n % f) * 1000000u / f;
}

void sa_sleep_ms(int ms) { Sleep((DWORD)(ms < 0 ? 0 : ms)); }

/* ---------------------------------------------------------------- measurements (API 3) */
#define COBJMACROS
#include <audioclient.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>

/* the interface ids, here so no uuid library is needed */
static const GUID sa_IID_IAudioClock = {0xCD63314F, 0x3FBA, 0x4A1B, {0x81, 0x2C, 0xEF, 0x96, 0x35, 0x87, 0x28, 0xE7}};
static const GUID sa_IID_IAudioSessionManager2 = {0x77AA99A0, 0x1BD6, 0x484F, {0x8B, 0xC7, 0x2C, 0x65, 0x4C, 0x9A, 0x9B, 0x6F}};
static const GUID sa_IID_IAudioSessionControl2 = {0xBFB7FF88, 0x7239, 0x4FC9, {0x8F, 0xA2, 0x07, 0xC9, 0x50, 0xBE, 0x9C, 0x6D}};
static const GUID sa_CLSID_MMDeviceEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const GUID sa_IID_IMMDeviceEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const GUID sa_IID_IAudioEndpointVolume = {0x5CDF2C82, 0x841E, 0x4546, {0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A}};

/* WASAPI's QPC positions are QPC converted to 100 ns: the same clock as sa_now_us64 */
uint64_t sa_device_time_us(uint64_t t) { return t / 10u; }

uint32_t sa_thread_cpu_us(void) {
    FILETIME c, e, k, u;
    if (!GetThreadTimes(GetCurrentThread(), &c, &e, &k, &u)) return 0;
    uint64_t kk = ((uint64_t)k.dwHighDateTime << 32) | k.dwLowDateTime, uu = ((uint64_t)u.dwHighDateTime << 32) | u.dwLowDateTime;
    return (uint32_t)((kk + uu) / 10u);
}

typedef struct {
    IAudioClock* clock;
    uint64_t freq;
} sa_wclock;

void* sa_wasapi_clock_open(void* audio_client) {
    if (!audio_client) return NULL;
    IAudioClock* c = NULL;
    if (FAILED(IAudioClient_GetService((IAudioClient*)audio_client, &sa_IID_IAudioClock, (void**)&c)) || !c) return NULL;
    UINT64 f = 0;
    if (FAILED(IAudioClock_GetFrequency(c, &f)) || f == 0) {
        IAudioClock_Release(c);
        return NULL;
    }
    sa_wclock* w = (sa_wclock*)malloc(sizeof(sa_wclock));
    if (!w) {
        IAudioClock_Release(c);
        return NULL;
    }
    w->clock = c;
    w->freq = f;
    return w;
}

int sa_wasapi_clock_read(void* clock, double rate, int64_t* pos_frames, int64_t* t_us) {
    sa_wclock* w = (sa_wclock*)clock;
    if (!w) return 0;
    UINT64 pos = 0, qpc = 0;
    if (FAILED(IAudioClock_GetPosition(w->clock, &pos, &qpc))) return 0;
    /* the position is in the clock's units (bytes or frames per second: its frequency) */
    *pos_frames = (int64_t)((double)pos * rate / (double)w->freq + 0.5);
    *t_us = (int64_t)(qpc / 10u);
    return 1;
}

void sa_wasapi_clock_close(void* clock) {
    sa_wclock* w = (sa_wclock*)clock;
    if (!w) return;
    IAudioClock_Release(w->clock);
    free(w);
}

typedef struct {
    IAudioEndpointVolume* v;
    DWORD hw;   /* ENDPOINT_HARDWARE_SUPPORT_*: what the device applies itself */
    HRESULT ci; /* this helper's CoInitializeEx, undone on close */
} sa_evol;

void* sa_endpoint_volume_open(const void* wasapi_id) {
    const wchar_t* id = (const wchar_t*)wasapi_id;
    HRESULT ci = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* en = NULL;
    IMMDevice* dev = NULL;
    IAudioEndpointVolume* v = NULL;
    sa_evol* e = NULL;
    if (FAILED(CoCreateInstance(&sa_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &sa_IID_IMMDeviceEnumerator, (void**)&en))) goto done;
    /* miniaudio's default output is the console role's */
    if (FAILED(id && id[0] ? IMMDeviceEnumerator_GetDevice(en, id, &dev) : IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev)))
        goto done;
    if (FAILED(IMMDevice_Activate(dev, &sa_IID_IAudioEndpointVolume, CLSCTX_ALL, NULL, (void**)&v)) || !v) goto done;
    e = (sa_evol*)malloc(sizeof(sa_evol));
    if (!e) goto done;
    e->v = v;
    e->hw = 0;
    if (FAILED(IAudioEndpointVolume_QueryHardwareSupport(v, &e->hw))) e->hw = 0;
    e->ci = ci;
    v = NULL;
done:
    if (v) IAudioEndpointVolume_Release(v);
    if (dev) IMMDevice_Release(dev);
    if (en) IMMDeviceEnumerator_Release(en);
    if (!e && SUCCEEDED(ci)) CoUninitialize();
    return e;
}

float sa_endpoint_volume_read(void* h) {
    sa_evol* e = (sa_evol*)h;
    if (!e) return -1.0f;
    float g = 1.0f;
    if (!(e->hw & ENDPOINT_HARDWARE_SUPPORT_VOLUME)) {
        /* the mixer attenuates a shared stream by the master level in dB (the slider's scalar is
           its taper onto that range); at the slider's 0 it is silent */
        float db = 0, scalar = 0;
        if (FAILED(IAudioEndpointVolume_GetMasterVolumeLevel(e->v, &db)) ||
            FAILED(IAudioEndpointVolume_GetMasterVolumeLevelScalar(e->v, &scalar)))
            return -1.0f;
        g = scalar <= 0 ? 0.0f : (db >= 0 ? 1.0f : powf(10.0f, db / 20.0f));
    }
    if (!(e->hw & ENDPOINT_HARDWARE_SUPPORT_MUTE)) {
        BOOL mute = FALSE;
        if (FAILED(IAudioEndpointVolume_GetMute(e->v, &mute))) return -1.0f;
        if (mute) g = 0.0f;
    }
    return g;
}

void sa_endpoint_volume_close(void* h) {
    sa_evol* e = (sa_evol*)h;
    if (!e) return;
    IAudioEndpointVolume_Release(e->v);
    if (SUCCEEDED(e->ci)) CoUninitialize();
    free(e);
}

static wchar_t* widen(const char* s);

int sa_output_sessions_active(const char* endpoint_id) {
    HRESULT ci = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int out = -1;
    IMMDeviceEnumerator* en = NULL;
    IMMDevice* dev = NULL;
    IAudioSessionManager2* mgr = NULL;
    IAudioSessionEnumerator* list = NULL;
    wchar_t* wid = endpoint_id && endpoint_id[0] ? widen(endpoint_id) : NULL;
    if (FAILED(CoCreateInstance(&sa_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &sa_IID_IMMDeviceEnumerator, (void**)&en))) goto done;
    if (wid ? FAILED(IMMDeviceEnumerator_GetDevice(en, wid, &dev))
            : FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev)))
        goto done;
    if (FAILED(IMMDevice_Activate(dev, &sa_IID_IAudioSessionManager2, CLSCTX_ALL, NULL, (void**)&mgr))) goto done;
    if (FAILED(IAudioSessionManager2_GetSessionEnumerator(mgr, &list))) goto done;
    int n = 0;
    if (FAILED(IAudioSessionEnumerator_GetCount(list, &n))) goto done;
    out = 0;
    DWORD me = GetCurrentProcessId();
    for (int i = 0; i < n; i++) {
        IAudioSessionControl* s = NULL;
        IAudioSessionControl2* s2 = NULL;
        if (FAILED(IAudioSessionEnumerator_GetSession(list, i, &s)) || !s) continue;
        AudioSessionState state = AudioSessionStateInactive;
        DWORD pid = 0;
        if (SUCCEEDED(IAudioSessionControl_GetState(s, &state)) && state == AudioSessionStateActive &&
            SUCCEEDED(IAudioSessionControl_QueryInterface(s, &sa_IID_IAudioSessionControl2, (void**)&s2)) && s2) {
            /* pid 0: the system sounds session, always there */
            if (SUCCEEDED(IAudioSessionControl2_GetProcessId(s2, &pid)) && pid != me && pid != 0) out++;
            IAudioSessionControl2_Release(s2);
        }
        IAudioSessionControl_Release(s);
    }
done:
    if (list) IAudioSessionEnumerator_Release(list);
    if (mgr) IAudioSessionManager2_Release(mgr);
    if (dev) IMMDevice_Release(dev);
    if (en) IMMDeviceEnumerator_Release(en);
    free(wid);
    if (SUCCEEDED(ci)) CoUninitialize();
    return out;
}

uint32_t sa_thread_id(void) { return (uint32_t)GetCurrentThreadId(); }

/* avrt.dll and winmm.dll are loaded when first needed (no import libraries, no load-time failure
 * on a system without them) */
typedef HANDLE(WINAPI* pf_AvSetMmThreadCharacteristicsW)(LPCWSTR, LPDWORD);
typedef BOOL(WINAPI* pf_AvSetMmThreadPriority)(HANDLE, int);
typedef UINT(WINAPI* pf_timePeriod)(UINT);
#define SA_AVRT_PRIORITY_NORMAL 0
#define SA_AVRT_PRIORITY_CRITICAL 2

static HMODULE avrt(void) {
    static HMODULE h;
    static int tried;
    if (!tried) {
        tried = 1;
        h = LoadLibraryW(L"avrt.dll");
    }
    return h;
}

int sa_rt_device_thread(void* mmcss_handle) {
    int flags = 0;
    HMODULE a = avrt();
    if (a) {
        pf_AvSetMmThreadCharacteristicsW reg = (pf_AvSetMmThreadCharacteristicsW)(void*)GetProcAddress(a, "AvSetMmThreadCharacteristicsW");
        pf_AvSetMmThreadPriority prio = (pf_AvSetMmThreadPriority)(void*)GetProcAddress(a, "AvSetMmThreadPriority");
        HANDLE h = (HANDLE)mmcss_handle;
        if (!h && reg) {
            /* miniaudio registers the thread itself (wasapi.usage = pro_audio); only when that failed */
            DWORD idx = 0;
            h = reg(L"Pro Audio", &idx);
        }
        if (h) {
            flags |= SA_RT_MMCSS;
            if (prio && prio(h, SA_AVRT_PRIORITY_CRITICAL)) flags |= SA_RT_CRITICAL;
        }
    }
    if (GetThreadPriority(GetCurrentThread()) == THREAD_PRIORITY_TIME_CRITICAL) flags |= SA_RT_TIME_CRITICAL;
    return flags;
}

int sa_rt_control_thread(void) {
    HMODULE a = avrt();
    if (!a) return 0;
    pf_AvSetMmThreadCharacteristicsW reg = (pf_AvSetMmThreadCharacteristicsW)(void*)GetProcAddress(a, "AvSetMmThreadCharacteristicsW");
    pf_AvSetMmThreadPriority prio = (pf_AvSetMmThreadPriority)(void*)GetProcAddress(a, "AvSetMmThreadPriority");
    if (!reg) return 0;
    DWORD idx = 0;
    HANDLE h = reg(L"Pro Audio", &idx);
    if (!h) return 0;
    if (prio) prio(h, SA_AVRT_PRIORITY_NORMAL);
    return SA_RT_MMCSS; /* reverted when the thread ends */
}

int sa_timer_1ms(int on) {
    static HMODULE w;
    static int held;
    if (!w) w = LoadLibraryW(L"winmm.dll");
    if (!w) return 0;
    if (on && !held) {
        pf_timePeriod begin = (pf_timePeriod)(void*)GetProcAddress(w, "timeBeginPeriod");
        if (begin && begin(1) == 0) held = 1;
    } else if (!on && held) {
        pf_timePeriod end = (pf_timePeriod)(void*)GetProcAddress(w, "timeEndPeriod");
        if (end) end(1);
        held = 0;
    }
    return held;
}

int sa_power_throttling_off(void) {
    /* SetProcessInformation(ProcessPowerThrottling): Windows 10 1709+; looked up so older systems load */
    typedef struct {
        ULONG Version, ControlMask, StateMask;
    } throttle_state;
    typedef BOOL(WINAPI * pf_spi)(HANDLE, int, LPVOID, DWORD);
    pf_spi spi = (pf_spi)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "SetProcessInformation");
    if (!spi) return 0;
    throttle_state s;
    s.Version = 1;              /* PROCESS_POWER_THROTTLING_CURRENT_VERSION */
    s.ControlMask = 0x1 | 0x4;  /* EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION */
    s.StateMask = 0;            /* both off: never throttled */
    if (spi(GetCurrentProcess(), 4 /* ProcessPowerThrottling */, &s, sizeof(s))) return 1;
    s.ControlMask = 0x1; /* before Windows 11: execution speed only */
    return spi(GetCurrentProcess(), 4, &s, sizeof(s)) ? 1 : 0;
}

int sa_ca_latency(uint32_t device_object_id, int input, int32_t* buffer_frames, int32_t* latency_frames) {
    (void)device_object_id;
    (void)input;
    *buffer_frames = 0;
    *latency_frames = 0;
    return 0;
}

void sa_wide_to_utf8(const void* wide, char* out, int size) {
    if (size <= 0) return;
    out[0] = 0;
    if (!wide) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, (const wchar_t*)wide, -1, out, size, NULL, NULL);
    if (n <= 0) out[0] = 0;
    out[size - 1] = 0;
}

typedef struct {
    void (*fn)(void*);
    void* arg;
} tramp;

static DWORD WINAPI thread_main(LPVOID p) {
    tramp t = *(tramp*)p;
    free(p);
    t.fn(t.arg);
    return 0;
}

sa_thread sa_thread_start(void (*fn)(void*), void* arg) {
    tramp* t = (tramp*)malloc(sizeof(tramp));
    if (!t) return NULL;
    t->fn = fn;
    t->arg = arg;
    HANDLE h = CreateThread(NULL, 0, thread_main, t, 0, NULL);
    if (!h) free(t);
    return (sa_thread)h;
}

void sa_thread_join(sa_thread t) {
    if (!t) return;
    WaitForSingleObject((HANDLE)t, INFINITE);
    CloseHandle((HANDLE)t);
}

static wchar_t* widen(const char* s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* w = (wchar_t*)malloc(sizeof(wchar_t) * (size_t)n);
    if (w && MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}

FILE* sa_fopen_utf8(const char* path, const char* mode) {
    wchar_t *wp = widen(path), *wm = widen(mode);
    FILE* f = NULL;
    if (wp && wm) f = _wfopen(wp, wm);
    free(wp);
    free(wm);
    return f;
}

int sa_documents_dir_impl(char* out, int size) {
    /* FOLDERID_Documents {FDD39AD0-238F-46AF-ADB4-6C85480369C7} */
    static const GUID documents = {0xFDD39AD0, 0x238F, 0x46AF, {0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7}};
    PWSTR w = NULL;
    int n = 0;
    if (SUCCEEDED(SHGetKnownFolderPath(&documents, 0, NULL, &w)) && w) {
        n = WideCharToMultiByte(CP_UTF8, 0, w, -1, out, size, NULL, NULL);
        n = n > 0 ? n - 1 : 0;
    }
    if (w) CoTaskMemFree(w);
    if (n == 0 && size > 0) out[0] = 0;
    return n;
}

int sa_is_striso_endpoint_w(const void* wasapi_id) {
    const wchar_t* id = (const wchar_t*)wasapi_id;
    wchar_t inst[400];
    DEVINST dn;
    if (!id || !id[0] || wcslen(id) > 300) return 0;
    wcscpy_s(inst, 400, L"SWD\\MMDEVAPI\\");
    wcscat_s(inst, 400, id);
    if (CM_Locate_DevNodeW(&dn, inst, CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS) return 0;
    for (int depth = 0; depth < 6; depth++) {
        wchar_t did[MAX_DEVICE_ID_LEN];
        if (CM_Get_Device_IDW(dn, did, MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS) {
            _wcsupr_s(did, MAX_DEVICE_ID_LEN);
            if (wcsstr(did, L"VID_F055&PID_57C0")) return 1;
        }
        DEVINST parent;
        if (CM_Get_Parent(&parent, dn, 0) != CR_SUCCESS) break;
        dn = parent;
    }
    return 0;
}

/* Walks up from the endpoint's device node: the first bus it hangs on says how it is connected
 * (an A2DP or hands-free endpoint sits under BTHENUM, a Bluetooth LE Audio one under BTHLEDevice /
 * BTHLE, a USB DAC under USB\, onboard codecs under HDAUDIO or INTELAUDIO). */
int sa_transport_endpoint_w(const void* wasapi_id) {
    const wchar_t* id = (const wchar_t*)wasapi_id;
    wchar_t inst[400];
    DEVINST dn;
    if (!id || !id[0] || wcslen(id) > 300) return SA_TRANSPORT_UNKNOWN;
    wcscpy_s(inst, 400, L"SWD\\MMDEVAPI\\");
    wcscat_s(inst, 400, id);
    if (CM_Locate_DevNodeW(&dn, inst, CM_LOCATE_DEVNODE_NORMAL) != CR_SUCCESS) return SA_TRANSPORT_UNKNOWN;
    for (int depth = 0; depth < 8; depth++) {
        wchar_t did[MAX_DEVICE_ID_LEN];
        if (depth > 0 && CM_Get_Device_IDW(dn, did, MAX_DEVICE_ID_LEN, 0) == CR_SUCCESS) {
            _wcsupr_s(did, MAX_DEVICE_ID_LEN);
            if (wcsstr(did, L"BTHENUM") || wcsstr(did, L"BTHLEDEVICE") || wcsstr(did, L"BTHLE\\") || wcsstr(did, L"BTHHFENUM"))
                return SA_TRANSPORT_BLUETOOTH;
            if (wcsncmp(did, L"USB\\", 4) == 0) return SA_TRANSPORT_USB;
            if (wcsncmp(did, L"HDAUDIO\\", 8) == 0 || wcsncmp(did, L"INTELAUDIO\\", 11) == 0) {
                /* an onboard codec; its HDMI / DisplayPort function names itself in the endpoint's
                   friendly name, which the app reads */
                return SA_TRANSPORT_BUILTIN;
            }
            if (wcsncmp(did, L"ROOT\\", 5) == 0 || wcsncmp(did, L"SWD\\DRIVERENUM", 14) == 0) return SA_TRANSPORT_VIRTUAL;
            if (wcsncmp(did, L"PCI\\", 4) == 0) return SA_TRANSPORT_PCI;
        }
        DEVINST parent;
        if (CM_Get_Parent(&parent, dn, 0) != CR_SUCCESS) break;
        dn = parent;
    }
    return SA_TRANSPORT_UNKNOWN;
}

int sa_transport_uid(const char* uid) {
    (void)uid;
    return SA_TRANSPORT_UNKNOWN;
}

int sa_is_striso_uid(const char* uid) {
    (void)uid;
    return 0;
}

int sa_mic_status(void) { return SA_MIC_NA; }
void sa_mic_request(void) {}

/* ======================================================================== POSIX */
#else
#include <ctype.h>
#include <pthread.h>
#include <time.h>

#if defined(__APPLE__)
/* mach_absolute_time (CLOCK_UPTIME_RAW): the clock of Core Audio's host times, so a device's own
 * timestamps convert exactly (sa_device_time_us) */
#include <mach/mach_time.h>
#define SA_MONO CLOCK_UPTIME_RAW
#else
#define SA_MONO CLOCK_MONOTONIC
#endif

uint32_t sa_now_us(void) {
    struct timespec ts;
    clock_gettime(SA_MONO, &ts);
    return (uint32_t)((uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u);
}

uint64_t sa_device_time_us(uint64_t t) {
#if defined(__APPLE__)
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (uint64_t)((double)t * tb.numer / tb.denom / 1000.0);
#else
    return t / 1000u;
#endif
}

uint32_t sa_thread_cpu_us(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0;
    return (uint32_t)((uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u);
}

void* sa_wasapi_clock_open(void* audio_client) {
    (void)audio_client;
    return NULL;
}
int sa_wasapi_clock_read(void* clock, double rate, int64_t* pos_frames, int64_t* t_us) {
    (void)clock;
    (void)rate;
    (void)pos_frames;
    (void)t_us;
    return 0;
}
void sa_wasapi_clock_close(void* clock) { (void)clock; }
void* sa_endpoint_volume_open(const void* wasapi_id) {
    (void)wasapi_id;
    return NULL;
}
float sa_endpoint_volume_read(void* h) {
    (void)h;
    return -1.0f;
}
void sa_endpoint_volume_close(void* h) { (void)h; }
int sa_output_sessions_active(const char* endpoint_id) {
    (void)endpoint_id;
    return -1;
}

void sa_sleep_ms(int ms) {
    struct timespec ts;
    if (ms < 0) ms = 0;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

typedef struct {
    void (*fn)(void*);
    void* arg;
} tramp;

static void* thread_main(void* p) {
    tramp t = *(tramp*)p;
    free(p);
    t.fn(t.arg);
    return NULL;
}

sa_thread sa_thread_start(void (*fn)(void*), void* arg) {
    pthread_t* th = (pthread_t*)malloc(sizeof(pthread_t));
    tramp* t = (tramp*)malloc(sizeof(tramp));
    if (!th || !t) {
        free(th);
        free(t);
        return NULL;
    }
    t->fn = fn;
    t->arg = arg;
    if (pthread_create(th, NULL, thread_main, t) != 0) {
        free(th);
        free(t);
        return NULL;
    }
    return (sa_thread)th;
}

void sa_thread_join(sa_thread t) {
    if (!t) return;
    pthread_join(*(pthread_t*)t, NULL);
    free(t);
}

FILE* sa_fopen_utf8(const char* path, const char* mode) { return fopen(path, mode); }

int sa_documents_dir_impl(char* out, int size) {
    const char* home = getenv("HOME");
    if (!home || size <= 0) return 0;
    int n = snprintf(out, (size_t)size, "%s/Documents", home);
    if (n < 0 || n >= size) {
        out[0] = 0;
        return 0;
    }
    return n;
}

int sa_is_striso_endpoint_w(const void* wasapi_id) {
    (void)wasapi_id;
    return 0;
}

uint64_t sa_now_us64(void) {
    struct timespec ts;
    clock_gettime(SA_MONO, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

uint32_t sa_thread_id(void) { return (uint32_t)(uintptr_t)pthread_self(); }

int sa_transport_endpoint_w(const void* wasapi_id) {
    (void)wasapi_id;
    return SA_TRANSPORT_UNKNOWN;
}

void sa_wide_to_utf8(const void* wide, char* out, int size) {
    (void)wide;
    if (size > 0) out[0] = 0;
}

/* Core Audio's HAL IO thread is real time already (time-constraint policy): nothing to add, and
 * nothing that could be wrong there */
int sa_rt_device_thread(void* mmcss_handle) {
    (void)mmcss_handle;
#if defined(__APPLE__)
    return SA_RT_HAL;
#else
    return 0;
#endif
}
int sa_rt_control_thread(void) { return 0; }
int sa_timer_1ms(int on) {
    (void)on;
    return 0;
}
int sa_power_throttling_off(void) { return 0; }

#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

static int has_ids(const char* s) {
    char low[512];
    size_t i = 0;
    for (; s[i] && i < sizeof(low) - 1; i++) low[i] = (char)tolower((unsigned char)s[i]);
    low[i] = 0;
    return strstr(low, "f055") != NULL && strstr(low, "57c0") != NULL;
}

/* USB audio devices carry their IDs in the model UID ("<product>:<vid>:<pid>"): untested on a
 * Striso, so the name is the fallback. */
int sa_is_striso_uid(const char* uid) {
    if (!uid || !uid[0]) return 0;
    if (has_ids(uid)) return 1;
    CFStringRef cfuid = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (!cfuid) return 0;
    AudioObjectID dev = kAudioObjectUnknown;
    AudioValueTranslation t;
    t.mInputData = &cfuid;
    t.mInputDataSize = sizeof(CFStringRef);
    t.mOutputData = &dev;
    t.mOutputDataSize = sizeof(dev);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 size = sizeof(t);
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &t);
    CFRelease(cfuid);
    if (st != noErr || dev == kAudioObjectUnknown) return 0;
    CFStringRef model = NULL;
    AudioObjectPropertyAddress m = {kAudioDevicePropertyModelUID, kAudioObjectPropertyScopeGlobal, 0};
    size = sizeof(model);
    int hit = 0;
    if (AudioObjectGetPropertyData(dev, &m, 0, NULL, &size, &model) == noErr && model) {
        char buf[512];
        if (CFStringGetCString(model, buf, sizeof(buf), kCFStringEncodingUTF8)) hit = has_ids(buf);
        CFRelease(model);
    }
    return hit;
}

static AudioObjectID device_for_uid(const char* uid) {
    AudioObjectID dev = kAudioObjectUnknown;
    if (!uid || !uid[0]) return dev;
    CFStringRef cfuid = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    if (!cfuid) return dev;
    AudioValueTranslation t;
    t.mInputData = &cfuid;
    t.mInputDataSize = sizeof(CFStringRef);
    t.mOutputData = &dev;
    t.mOutputDataSize = sizeof(dev);
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 size = sizeof(t);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &t) != noErr) dev = kAudioObjectUnknown;
    CFRelease(cfuid);
    return dev;
}

int sa_transport_uid(const char* uid) {
    AudioObjectID dev = device_for_uid(uid);
    if (dev == kAudioObjectUnknown) return SA_TRANSPORT_UNKNOWN;
    UInt32 tt = 0, size = sizeof(tt);
    AudioObjectPropertyAddress a = {kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0};
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &tt) != noErr) return SA_TRANSPORT_UNKNOWN;
    switch (tt) {
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: return SA_TRANSPORT_BLUETOOTH;
        case kAudioDeviceTransportTypeUSB: return SA_TRANSPORT_USB;
        case kAudioDeviceTransportTypeBuiltIn: return SA_TRANSPORT_BUILTIN;
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort: return SA_TRANSPORT_HDMI;
        case kAudioDeviceTransportTypeThunderbolt: return SA_TRANSPORT_THUNDERBOLT;
        case kAudioDeviceTransportTypePCI: return SA_TRANSPORT_PCI;
        case kAudioDeviceTransportTypeAggregate:
        case kAudioDeviceTransportTypeAutoAggregate:
        case kAudioDeviceTransportTypeVirtual:
        case kAudioDeviceTransportTypeAirPlay: return SA_TRANSPORT_VIRTUAL;
        default: return SA_TRANSPORT_UNKNOWN;
    }
}

static UInt32 ca_u32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    UInt32 v = 0, size = sizeof(v);
    AudioObjectPropertyAddress a = {sel, scope, 0};
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &v) != noErr) return 0;
    return v;
}

int sa_ca_latency(uint32_t device_object_id, int input, int32_t* buffer_frames, int32_t* latency_frames) {
    *buffer_frames = 0;
    *latency_frames = 0;
    if (!device_object_id) return 0;
    AudioObjectPropertyScope scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
    AudioObjectID dev = (AudioObjectID)device_object_id;
    UInt32 buf = ca_u32(dev, kAudioDevicePropertyBufferFrameSize, scope);
    UInt32 lat = ca_u32(dev, kAudioDevicePropertyLatency, scope) + ca_u32(dev, kAudioDevicePropertySafetyOffset, scope);
    /* the first stream's own latency */
    AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreams, scope, 0};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(dev, &sa, 0, NULL, &size) == noErr && size >= sizeof(AudioStreamID)) {
        AudioStreamID streams[16];
        if (size > sizeof(streams)) size = sizeof(streams);
        if (AudioObjectGetPropertyData(dev, &sa, 0, NULL, &size, streams) == noErr && size >= sizeof(AudioStreamID))
            lat += ca_u32(streams[0], kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal);
    }
    *buffer_frames = (int32_t)buf;
    *latency_frames = (int32_t)lat;
    return 1;
}

/* AVCaptureDevice through the Objective-C runtime (this library is C). */
extern id const AVMediaTypeAudio;
static volatile uint32_t g_mic_answer = 0; /* 0 none yet, else SA_MIC_* + 10 */

int sa_mic_status(void) {
    Class c = (Class)objc_getClass("AVCaptureDevice");
    if (!c) return SA_MIC_NA;
    uint32_t ans = sa_ld(&g_mic_answer);
    SEL s = sel_registerName("authorizationStatusForMediaType:");
    long v = ((long (*)(id, SEL, id))objc_msgSend)((id)c, s, AVMediaTypeAudio);
    if (v == SA_MIC_UNDETERMINED && ans >= 10) return (int)ans - 10;
    return (int)v;
}

void sa_mic_request(void) {
    Class c = (Class)objc_getClass("AVCaptureDevice");
    if (!c) return;
    SEL s = sel_registerName("requestAccessForMediaType:completionHandler:");
    void (^done)(BOOL) = ^(BOOL granted) {
      sa_st(&g_mic_answer, granted ? 10u + SA_MIC_AUTHORIZED : 10u + SA_MIC_DENIED);
    };
    ((void (*)(id, SEL, id, void (^)(BOOL)))objc_msgSend)((id)c, s, AVMediaTypeAudio, done);
}

#else /* other POSIX: no IDs, no permission */
int sa_is_striso_uid(const char* uid) {
    (void)uid;
    return 0;
}
int sa_transport_uid(const char* uid) {
    (void)uid;
    return SA_TRANSPORT_UNKNOWN;
}
int sa_ca_latency(uint32_t device_object_id, int input, int32_t* buffer_frames, int32_t* latency_frames) {
    (void)device_object_id;
    (void)input;
    *buffer_frames = 0;
    *latency_frames = 0;
    return 0;
}
int sa_mic_status(void) { return SA_MIC_NA; }
void sa_mic_request(void) {}
#endif
#endif
