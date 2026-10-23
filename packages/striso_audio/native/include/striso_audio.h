/* striso_audio: the Striso's USB audio input through the computer, for Striso Live.
 *
 * A small native library around miniaudio (WASAPI on Windows, Core Audio on macOS):
 *   - capture from the Striso Synth input (found by USB VID/PID where the OS says, else by name),
 *   - play it to an output device (duplex passthrough with drift compensation),
 *   - record it to a WAV file.
 * All audio work runs on miniaudio's device threads and one control thread of this library. The
 * caller (Dart through dart:ffi) only sets the wanted state and reads the status; no call blocks
 * on a device except sa_init and sa_shutdown.
 *
 * Every string is UTF-8. Every function is safe to call from any thread.
 */
#ifndef STRISO_AUDIO_H
#define STRISO_AUDIO_H

#include <stdint.h>

#if defined(_WIN32)
#  if defined(SA_BUILD_DLL)
#    define SA_API __declspec(dllexport)
#  else
#    define SA_API __declspec(dllimport)
#  endif
#else
#  define SA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped whenever a struct or a function below changes. */
#define SA_API_VERSION 1

/* sa_init backends */
#define SA_BACKEND_SYSTEM 0 /* WASAPI on Windows, Core Audio on macOS */
#define SA_BACKEND_NULL   1 /* miniaudio's null backend: silent devices with real timing (tests) */

/* device states (sa_status.capture_state, playback_state) */
#define SA_DEV_CLOSED 0
#define SA_DEV_RUNNING 1
#define SA_DEV_LOST 2   /* was running, stopped by itself (unplugged, the board restarted) */
#define SA_DEV_FAILED 3 /* could not be opened: see the error */

/* recording states */
#define SA_REC_IDLE 0
#define SA_REC_ON 1
#define SA_REC_STOPPED 2 /* stopped by itself (input lost, disk full, file error): see record_error */

/* errors */
#define SA_OK 0
#define SA_ERR_NO_CONTEXT -1        /* the audio system could not be initialised */
#define SA_ERR_NOT_FOUND -2         /* no such input (or output) device */
#define SA_ERR_OPEN_CAPTURE -3      /* the input exists but would not open */
#define SA_ERR_OPEN_PLAYBACK -4     /* the output would not open */
#define SA_ERR_PERMISSION -5        /* macOS: audio input is not allowed for this app */
#define SA_ERR_LOST -6              /* the device went away while running */
#define SA_ERR_FILE -7              /* the WAV file could not be created or written */
#define SA_ERR_FILE_FULL -8         /* the WAV file reached its 4 GB limit */
#define SA_ERR_NOT_RUNNING -9       /* recording needs the input running */
#define SA_ERR_BAD_ARG -10
#define SA_ERR_NOT_INITIALISED -11

/* sa_configure exclusive flags (Windows; ignored elsewhere) */
#define SA_EXCLUSIVE_INPUT 1  /* the input alone: its own format, short periods */
#define SA_EXCLUSIVE_OUTPUT 2 /* the output alone: lowest latency; other programs cannot play to it meanwhile */

/* macOS microphone permission (sa_status.mic_permission); -1 elsewhere */
#define SA_MIC_NA -1
#define SA_MIC_UNDETERMINED 0
#define SA_MIC_RESTRICTED 1
#define SA_MIC_DENIED 2
#define SA_MIC_AUTHORIZED 3

/* One device of the last enumeration. All fields 4 bytes wide (no padding). */
typedef struct sa_device {
    char name[256];         /* UTF-8, NUL terminated */
    int32_t is_default;     /* the system's default device of its kind */
    int32_t is_striso;      /* identified as the Striso by USB VID 0xF055 / PID 0x57C0 */
    int32_t native_bits;    /* 16, 24, 32 (integer), -32 (float) or 0 (unknown) */
    int32_t native_rate;    /* Hz or 0 */
    int32_t native_channels;
} sa_device;

/* Status, read with sa_get_status. Every field 4 bytes wide (no padding). */
typedef struct sa_status {
    int32_t api_version;      /* SA_API_VERSION */
    int32_t initialised;      /* sa_init succeeded */
    int32_t backend;          /* SA_BACKEND_* */
    uint32_t config_gen;      /* generation of the last sa_configure the control thread applied */
    uint32_t devices_gen;     /* bumped after every enumeration */

    int32_t capture_state;    /* SA_DEV_* */
    int32_t capture_error;    /* SA_ERR_* */
    int32_t capture_result;   /* miniaudio's ma_result of the failure, for the log */
    int32_t capture_rate;     /* Hz */
    int32_t capture_channels;
    int32_t capture_period;   /* frames per device period */
    int32_t capture_exclusive;/* Windows: opened in exclusive mode */
    int32_t capture_bits;     /* what the device delivers: 16, 24, 32, -32 (float) */
    uint32_t capture_callbacks;

    int32_t playback_state;
    int32_t playback_error;
    int32_t playback_result;
    int32_t playback_rate;
    int32_t playback_period;
    int32_t playback_periods;
    uint32_t playback_callbacks;

    float level_l;            /* input peak, 0..1 (decaying, about 300 ms) */
    float level_r;
    float level_out;          /* output peak after the gain */
    float gain;               /* linear output gain in use */

    float latency_ms;         /* buffering through the computer: input period + ring + output buffer */
    float ring_ms;            /* the passthrough ring alone (smoothed) */
    float target_ms;          /* what the ring aims at */
    float drift_ppm;          /* rate correction the drift servo applies (input vs output clock) */
    uint32_t underruns;       /* output ran dry (counts since the output opened) */
    uint32_t overruns;        /* input dropped because the ring was full */
    uint32_t resyncs;         /* the ring was too full and was cut back */
    int32_t streaming;        /* the output is playing the input (not priming) */

    int32_t record_state;     /* SA_REC_* */
    int32_t record_error;
    int32_t record_bits;      /* 16, 24 or -32 (float) */
    uint32_t record_frames;   /* frames written so far */
    uint32_t record_dropped;  /* frames lost because the disk was too slow */

    int32_t mic_permission;   /* SA_MIC_* */
    int32_t playback_exclusive; /* Windows: the output opened in exclusive mode */
    uint32_t reserved[3];
} sa_status;

/* Version of this library (SA_API_VERSION) and of miniaudio (e.g. "0.11.25"). */
SA_API int32_t sa_api_version(void);
SA_API const char* sa_miniaudio_version(void);
/* sizeof(sa_status) and sizeof(sa_device), so a binding can check its layout. */
SA_API int32_t sa_sizeof_status(void);
SA_API int32_t sa_sizeof_device(void);

/* Starts the control thread and the audio system (SA_BACKEND_*). Opens no device. Returns SA_OK,
 * or SA_ERR_NO_CONTEXT. Calling it again while initialised returns SA_OK. */
SA_API int32_t sa_init(int32_t backend);

/* Closes every device (finishing a recording), stops the control thread. */
SA_API void sa_shutdown(void);

/* Asks for a fresh device list; devices_gen goes up when it is ready. */
SA_API void sa_enumerate(void);
SA_API int32_t sa_device_count(int32_t capture);
/* Copies device i of the last enumeration; returns SA_OK or SA_ERR_BAD_ARG. */
SA_API int32_t sa_device_get(int32_t capture, int32_t i, sa_device* out);

/* The wanted state; the control thread opens and closes devices to match it.
 *   run      0: everything closed (a recording is finished first)
 *   input    exact device name, or "" for the Striso (VID/PID, else a name with "Striso")
 *   output   exact device name, or "" for the system default (followed when it changes)
 *   period   frames per device period (e.g. 64, 128, 256)
 *   monitor  1: play the input to the output; 0: input only (meters, recording)
 *   exclusive  Windows, SA_EXCLUSIVE_* flags: try the input (1) and/or the output (2) in
 *            exclusive mode first (lower latency; the input in its own format); each falls back to
 *            shared mode.
 * Returns the configuration's generation: status.config_gen reaches it once applied. Every call
 * counts as a new request, so calling it again retries a device that failed or was lost. */
SA_API uint32_t sa_configure(int32_t run, const char* input, const char* output, int32_t period, int32_t monitor, int32_t exclusive);

/* Linear output gain, applied at once (smoothed over about 10 ms). Clamped to 0..4. */
SA_API void sa_set_gain(float gain);

/* Starts recording the input to a new WAV file at path (UTF-8); the folder must exist. The format
 * follows the device: 24 bit when it gives 24 (or 32), 16 when it gives 16, else 32-bit float.
 * Needs the input running (else record_state SA_REC_STOPPED, record_error SA_ERR_NOT_RUNNING). */
SA_API void sa_record_start(const char* path);
/* Finishes the file (header sizes written). */
SA_API void sa_record_stop(void);

SA_API void sa_get_status(sa_status* out);

/* The user's Documents folder (Windows: the known folder, also when moved to OneDrive; macOS:
 * ~/Documents), UTF-8, into out. Returns its length or 0. */
SA_API int32_t sa_documents_dir(char* out, int32_t size);

/* macOS: asks the user for audio input permission (the system prompt); the answer arrives in
 * status.mic_permission. Elsewhere does nothing. */
SA_API void sa_request_mic(void);

/* Self-tests of the passthrough math, the resampler, the drift servo, the WAV writer and a
 * session on the null backend. Writes a report (UTF-8 lines) into report and its scratch files
 * into dir. Returns the number of failures. Must not run while the app uses the library. */
SA_API int32_t sa_selftest(const char* dir, char* report, int32_t report_size);

#ifdef __cplusplus
}
#endif

#endif
