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
uint64_t sa_now_us64(void); /* monotonic, the same clock without the wrap */
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

/* How the device is connected (SA_TRANSPORT_*): Windows from the endpoint's device tree (BTHENUM,
 * BTHLEDevice, USB, HDAUDIO, ...), macOS from kAudioDevicePropertyTransportType. */
int sa_transport_endpoint_w(const void* wasapi_id_wchar);
int sa_transport_uid(const char* coreaudio_uid);

/* The endpoint id as UTF-8 (Windows). */
void sa_wide_to_utf8(const void* wide, char* out, int size);

/* Real-time scheduling, Windows (no-ops elsewhere, returning 0 or SA_RT_HAL):
 *   sa_rt_device_thread  on an audio device thread, once: AVRT_PRIORITY_CRITICAL on the MMCSS task
 *                        miniaudio registered ("Pro Audio"), or a registration of its own when there
 *                        is none. Returns SA_RT_* flags.
 *   sa_rt_control_thread the library's control thread: MMCSS "Pro Audio" at normal priority (it
 *                        opens devices and writes files; it must never preempt the device threads)
 *   sa_timer_1ms         timeBeginPeriod(1) on / timeEndPeriod(1) off; returns 1 while held
 *   sa_power_throttling_off  the process opts out of EcoQoS execution-speed throttling and of
 *                        Windows 11's timer-resolution throttling when minimised; 1 if accepted */
int sa_rt_device_thread(void* mmcss_handle);
int sa_rt_control_thread(void);
int sa_timer_1ms(int on);
int sa_power_throttling_off(void);
uint32_t sa_thread_id(void);

/* macOS: the device's IO buffer (frames) and what Core Audio adds on top: device latency + the
 * first stream's latency + safety offset (frames), for the scope. 0 elsewhere / on failure. */
int sa_ca_latency(uint32_t device_object_id, int input, int32_t* buffer_frames, int32_t* latency_frames);

/* macOS: AVAuthorizationStatus for audio (0..3), -1 elsewhere. */
int sa_mic_status(void);
/* macOS: shows the system prompt; the answer lands in sa_mic_status. */
void sa_mic_request(void);

#endif
