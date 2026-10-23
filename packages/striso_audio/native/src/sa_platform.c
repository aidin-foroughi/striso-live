/* The operating-system bits of striso_audio: see sa_platform.h. */
#include "sa_platform.h"
#include "sa_core.h"
#include "striso_audio.h"

#include <stdlib.h>
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

void sa_sleep_ms(int ms) { Sleep((DWORD)(ms < 0 ? 0 : ms)); }

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

uint32_t sa_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)((uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u);
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
int sa_mic_status(void) { return SA_MIC_NA; }
void sa_mic_request(void) {}
#endif
#endif
