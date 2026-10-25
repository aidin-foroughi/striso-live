/* striso_midi: MIDI input for Striso Live's Virtual mode, in the striso_audio library.
 *
 * Any MIDI or MPE controller the system sees (a Striso through its USB MIDI port, a LinnStrument,
 * a keyboard) plays the virtual Striso (striso_virtual): the raw MIDI of the open inputs goes, on
 * the MIDI driver's own thread, through a byte-stream parser per input into one sink function as
 * USB-MIDI event packets (striso_virtual's sv_midi_write). No mapping and no Dart on that path.
 *
 *   Windows  WinMM: midiInOpen with CALLBACK_FUNCTION; the callback runs on WinMM's thread.
 *            MIDI 2.0: Windows MIDI Services (striso_midi_wms.cpp): its UMP-native endpoints, the
 *            service's callback thread delivering.
 *   macOS    CoreMIDI: one client and two input ports (MIDI 1.0 bytes; MIDI 2.0 UMP, protocol 2.0),
 *            created on a thread of this library that runs a CFRunLoop (so the system's source list
 *            stays current without the caller's run loop); the read procs run on CoreMIDI's own
 *            high-priority thread. A source whose protocol is MIDI 2.0 (kMIDIPropertyProtocolID) is
 *            connected to the UMP port, every other one to the byte port.
 *
 * MIDI 2.0 inputs (protocol 2) deliver Universal MIDI Packets, 32-bit words, whole packets as the
 * system gives them, untouched, to the UMP sink (striso_virtual's sv_ump_write): no translation
 * either way. Their monitor events have len 4 (bytes: the first word's status and two data bytes).
 *   other    no system inputs (sa_midi_inject only).
 *
 * Packets: 4 bytes each, byte 0 = cable << 4 | CIN (cable 0; CIN 0x8..0xE from the status nibble),
 * then the message's status and data bytes, padded with 0 (program change and channel pressure
 * have one data byte). Only channel messages are passed: system common and real-time (clock F8,
 * active sensing FE, ...) are dropped, and so is SysEx (with every data byte inside it). Running
 * status is expanded; real-time bytes between a status and its data do not disturb it. A note-on
 * with velocity 0 passes unchanged.
 *
 * Devices are kept by a stable id: macOS, the source's kMIDIPropertyUniqueID in decimal; Windows,
 * the device name, with "#2", "#3", ... appended for duplicates in enumeration order (WinMM's
 * indices shift on hot-plug). Each id keeps its slot number (sa_midi_device.slot, the events'
 * device) while the library stays initialised. There is no hot-plug notification: sa_midi_refresh
 * re-enumerates and bumps the generation when the set changed. An open input that disappears is
 * closed and stays listed with present 0 and error SA_ERR_MIDI_GONE; when it comes back it is
 * listed again (present 1), closed, still with that error, until the caller opens it again (or
 * closes it, which forgets the error).
 *
 * Times are sa_clock_us (the library's monotonic clock, striso_audio.h).
 * Every function is safe to call from any thread, except from inside the sink (the sink must not
 * call sa_midi_*: it runs with the delivery lock held).
 */
#ifndef STRISO_MIDI_H
#define STRISO_MIDI_H

#include "striso_audio.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Bumped whenever a struct or a function below changes. (Separate from SA_API_VERSION: a library
 * without MIDI has no sa_midi_api_version, and the audio binding's version check stays as it is.) */
#define SA_MIDI_API_VERSION 3

/* errors (besides SA_OK, SA_ERR_NOT_FOUND, SA_ERR_BAD_ARG, SA_ERR_NOT_INITIALISED of striso_audio.h) */
#define SA_ERR_MIDI_IN_USE -20  /* Windows: another program has that input open (MMSYSERR_ALLOCATED) */
#define SA_ERR_MIDI_OPEN -21    /* the system would not open or start it: os_error has its code */
#define SA_ERR_MIDI_GONE -22    /* it was open and disappeared (unplugged) */
#define SA_ERR_MIDI_SYSTEM -23  /* the MIDI system could not be set up (macOS: MIDIClientCreate / MIDIInputPortCreate) */
#define SA_ERR_MIDI_FULL -24    /* no free slot (64 ids at most) */

#define SA_MIDI_MAX 64          /* devices (ids) the library keeps at once */
#define SA_MIDI_RING 4096       /* monitor events kept until read */

/* One input of the list. 808 bytes, no implicit padding. */
typedef struct sa_midi_device {
    char name[256];      /* UTF-8, NUL terminated (Windows: WinMM's name, at most 31 characters) */
    char id[256];        /* stable id (see above) */
    int32_t open;        /* 1: open and started (a virtual device: always) */
    int32_t error;       /* SA_OK, or what happened last: SA_ERR_MIDI_IN_USE, _OPEN, _GONE */
    uint32_t messages;   /* channel messages it produced since its slot was made (wraps) */
    int32_t slot;        /* stable while the library is initialised: sa_midi_event.device */
    int64_t last_us;     /* sa_clock_us of its last channel message, 0: none yet */
    int32_t present;     /* 1: the system lists it now (virtual: 1) */
    int32_t is_virtual;  /* 1: made by sa_midi_inject, no system port */
    int32_t os_error;    /* the system's code of the last failure (MMRESULT, OSStatus), 0 none */
    int32_t protocol;    /* 1: MIDI 1.0 bytes (to the sink), 2: MIDI 2.0 UMP (to the UMP sink) */
    char link[256];      /* the physical device: two inputs with the same non-empty link are two views of one
                            port (Windows: a MIDI 2.0 endpoint and the WinMM port Windows MIDI Services makes
                            for it, by the service's own association; macOS: the source's entity). "" : none */
} sa_midi_device;

/* One channel message that went to the sink (or would have: the monitor records them with no sink
 * set too). 16 bytes. */
typedef struct sa_midi_event {
    int64_t t_us;        /* sa_clock_us when the driver (or sa_midi_inject) delivered it */
    int32_t device;      /* the device's slot */
    uint8_t len;         /* 2 or 3; 4: a UMP packet (MIDI 2.0 input) */
    uint8_t bytes[3];    /* status, data (unused bytes 0) */
} sa_midi_event;

SA_API int32_t sa_midi_api_version(void);
SA_API int32_t sa_midi_sizeof_device(void);
SA_API int32_t sa_midi_sizeof_event(void);

/* Sets up the system's MIDI (macOS: the client, its input port and their run-loop thread) and
 * enumerates once. Opens nothing. Idempotent: SA_OK when already initialised, or
 * SA_ERR_MIDI_SYSTEM. Independent of sa_init (the audio). */
SA_API int32_t sa_midi_init(void);

/* Closes every input, clears the sink, forgets every device (virtual ones too), empties the
 * monitor, and releases the system's MIDI (macOS: the client and its thread). */
SA_API void sa_midi_shutdown(void);

/* Re-enumerates the system's inputs now (a few system calls, no device is opened). Closes an open
 * input that disappeared (error SA_ERR_MIDI_GONE). Returns the list generation, bumped whenever
 * the listed devices (ids, names, present) changed. Without sa_midi_init: only the virtual
 * devices, the generation unchanged. */
SA_API uint32_t sa_midi_refresh(void);

/* The list of the last refresh: the system's inputs in enumeration order, then inputs gone while
 * open, then virtual devices. */
SA_API int32_t sa_midi_count(void);
SA_API int32_t sa_midi_get(int32_t i, sa_midi_device* out); /* SA_OK or SA_ERR_BAD_ARG */

/* Opens and starts that input (it refreshes first, so a WinMM index is current). SA_OK (also when
 * it is open already), SA_ERR_NOT_FOUND, SA_ERR_MIDI_IN_USE, SA_ERR_MIDI_OPEN, or
 * SA_ERR_NOT_INITIALISED. */
SA_API int32_t sa_midi_open(const char* id);
/* Stops and closes it; no message of it reaches the sink after this returns. A virtual device, or
 * one that is gone, is forgotten. SA_OK or SA_ERR_NOT_FOUND. */
SA_API int32_t sa_midi_close(const char* id);
SA_API void sa_midi_close_all(void);

/* The sink: called on the driver's thread with n bytes (a multiple of 4) of USB-MIDI packets, one
 * call per batch the driver delivered (WinMM: one message; CoreMIDI: up to a packet list). Its
 * return value is ignored. NULL: the messages are only counted and monitored.
 * sa_midi_set_sink returns only when no call to the previous sink is still running (it takes the
 * delivery lock, which every sink call holds), so the caller can destroy the previous user right
 * after. Works without sa_midi_init. */
typedef int32_t (*sa_midi_sink_fn)(void* user, const uint8_t* packets, int32_t n);
SA_API void sa_midi_set_sink(sa_midi_sink_fn fn, void* user);

/* Feeds raw MIDI bytes (any mix: running status, real-time, SysEx) through the same parser, sink,
 * counters and monitor as the device with that id. An id that is no system input makes (or
 * reuses) a virtual device of that id: listed with is_virtual 1, always open, needing no system
 * port and no sa_midi_init (tests, a fake controller). Returns the channel messages produced, or
 * SA_ERR_BAD_ARG / SA_ERR_MIDI_FULL. Bytes to a closed system input are dropped (0). */
SA_API int32_t sa_midi_inject(const char* id, const uint8_t* bytes, int32_t n);

/* The UMP sink: called on the driver's thread with n 32-bit words of whole Universal MIDI Packets
 * from a MIDI 2.0 input, exactly as the system delivered them. Same rules as sa_midi_set_sink (the
 * same delivery lock). NULL: counted and monitored only. */
typedef int32_t (*sa_midi_ump_sink_fn)(void* user, const uint32_t* words, int32_t n);
SA_API void sa_midi_set_ump_sink(sa_midi_ump_sink_fn fn, void* user);
/* Feeds UMP words, untouched, to the UMP sink as the MIDI 2.0 input with that id; an id that is no
 * system input makes a virtual MIDI 2.0 device (protocol 2). Returns the packets counted, or
 * SA_ERR_BAD_ARG / SA_ERR_MIDI_FULL. */
SA_API int32_t sa_midi_inject_ump(const char* id, const uint32_t* words, int32_t n);
/* Windows: what Windows MIDI Services said (empty: it is there), so the app can tell why there is
 * no MIDI 2.0; other systems: "". */
SA_API int32_t sa_midi2_status(char* out, int32_t max);

/* Takes up to max monitor events, oldest first; returns how many. The ring keeps SA_MIDI_RING;
 * when it is full newer events are dropped (counted in sa_midi_events_lost) until it is read. */
SA_API int32_t sa_midi_events(sa_midi_event* out, int32_t max);
SA_API uint32_t sa_midi_events_lost(void);

/* Tests: a sink that records what it gets (up to 64 KB, the rest is dropped). Its address is
 * the symbol's (dart:ffi: lib.lookup('sa_midi_test_sink').address). sa_midi_test_sink_read takes
 * up to max recorded bytes (oldest first) and returns how many. */
SA_API int32_t sa_midi_test_sink(void* user, const uint8_t* packets, int32_t n);
SA_API int32_t sa_midi_test_sink_read(uint8_t* out, int32_t max);
/* Tests, MIDI 2.0: a UMP sink that records the words it gets, and a MIDI 2.0 source of the system
 * that this process sends into: macOS, a CoreMIDI virtual source of protocol 2.0; Windows, Windows
 * MIDI Services' diagnostic loopback (A sends, B is listed as the input). sa_midi_test_ump_source
 * writes the id of the input that receives it (open that) and returns SA_OK, or an error when the
 * system has none; sa_midi_test_ump_send sends whole UMP words through it. */
SA_API int32_t sa_midi_test_ump_sink(void* user, const uint32_t* words, int32_t n);
SA_API int32_t sa_midi_test_ump_sink_read(uint32_t* out, int32_t max);
SA_API int32_t sa_midi_test_ump_source(char* id_out, int32_t max);
SA_API int32_t sa_midi_test_ump_send(const uint32_t* words, int32_t n);

#ifdef __cplusplus
}
#endif

#endif
