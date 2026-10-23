/* The operating-system bits of striso_audio: clock, sleep, threads, UTF-8 file names, the
 * Documents folder, telling the Striso's audio endpoint by its USB IDs, and (macOS) the audio
 * input permission. Kept apart from miniaudio's translation unit (windows.h, cfgmgr32.h, objc). */
#ifndef SA_PLATFORM_H
#define SA_PLATFORM_H

#include <stdint.h>
#include <stdio.h>

#define SA_STRISO_VID 0xF055
#define SA_STRISO_PID 0x57C0

uint32_t sa_now_us(void); /* monotonic, wraps every 71 minutes */
void sa_sleep_ms(int ms);

typedef void* sa_thread;
sa_thread sa_thread_start(void (*fn)(void*), void* arg); /* NULL on failure */
void sa_thread_join(sa_thread t);

FILE* sa_fopen_utf8(const char* path, const char* mode);
int sa_documents_dir_impl(char* out, int size);

/* Windows: endpoint is a WASAPI endpoint id ("{0.0.1.00000000}.{guid}"); macOS: a Core Audio
 * device UID. 1 when the device or one of its parents is USB VID_F055&PID_57C0. */
int sa_is_striso_endpoint_w(const void* wasapi_id_wchar);
int sa_is_striso_uid(const char* coreaudio_uid);

/* macOS: AVAuthorizationStatus for audio (0..3), -1 elsewhere. */
int sa_mic_status(void);
/* macOS: shows the system prompt; the answer lands in sa_mic_status. */
void sa_mic_request(void);

#endif
