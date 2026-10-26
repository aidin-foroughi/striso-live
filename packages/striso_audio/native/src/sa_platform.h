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

/* Measurements (API 3):
 *   sa_device_time_us    a device timestamp on sa_now_us64's clock: Windows, WASAPI's QPC position
 *                        (100 ns units); macOS, a Core Audio host time (mach ticks)
 *   sa_thread_cpu_us     CPU time of the calling thread (us, wraps)
 *   sa_wasapi_clock_*    Windows: the output's IAudioClock, from its IAudioClient (NULL elsewhere);
 *                        read gives the play position in frames at rate and its time (sa_now_us64)
 *   sa_output_sessions_active  Windows: other processes' active sessions on the output endpoint
 *                        (endpoint_id_utf8 NULL or "": the default output); -1 unknown */
uint64_t sa_device_time_us(uint64_t t);
uint32_t sa_thread_cpu_us(void);
void* sa_wasapi_clock_open(void* audio_client);
int sa_wasapi_clock_read(void* clock, double rate, int64_t* pos_frames, int64_t* t_us);
void sa_wasapi_clock_close(void* clock);
int sa_output_sessions_active(const char* endpoint_id_utf8);

/* Windows: the output endpoint's volume, for an exclusive stream (the Windows mixer, and so the
 * system volume, does not touch one). open takes the endpoint's id (wide, miniaudio's
 * ma_device_id.wasapi; NULL or "": the default output) and gives NULL when it cannot be read
 * (and NULL elsewhere). read: the linear gain the app must apply for the stream to sound as a
 * shared one at the same volume: 1 for what the device applies itself (a hardware volume or
 * mute), 0 muted; -1 when it cannot be read. Open, read and close on one thread. */
void* sa_endpoint_volume_open(const void* wasapi_id);
float sa_endpoint_volume_read(void* h);
void sa_endpoint_volume_close(void* h);

/* macOS: AVAuthorizationStatus for audio (0..3), -1 elsewhere. */
int sa_mic_status(void);
/* macOS: shows the system prompt; the answer lands in sa_mic_status. */
void sa_mic_request(void);

#endif
