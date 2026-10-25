/* striso_midi's byte-stream parser, shared with the self-test (selftest_midi.c). */
#ifndef SA_MIDI_INTERNAL_H
#define SA_MIDI_INTERNAL_H

#include <stdint.h>

/* One input's state: the running status and the data bytes of the message in progress. */
typedef struct sa_midi_parser {
    uint8_t status; /* running status (0x80..0xEF), 0: none */
    uint8_t have;   /* data bytes collected */
    uint8_t need;   /* data bytes the status takes (1 or 2) */
    uint8_t skip;   /* data bytes of a system common message still to swallow */
    uint8_t sysex;  /* inside F0 ... F7 */
    uint8_t data[2];
} sa_midi_parser;

void sa_midi_parser_reset(sa_midi_parser* p);

/* Parses bytes, writing one 4-byte USB-MIDI packet (cable 0) per complete channel message into
 * out, at most max_packets. Returns the packets written; *used (may be NULL) the bytes consumed
 * (less than n only when out filled up: call again with the rest). */
int sa_midi_parse(sa_midi_parser* p, const uint8_t* in, int n, uint8_t* out, int max_packets, int* used);

/* the self-test's MIDI part (selftest_midi.c); say/check are selftest.c's */
void sa_selftest_midi(void (*say)(const char* fmt, ...), void (*check)(int ok, const char* what));
int sa_midi_internal_inited(void);

/* MIDI 2.0: whole UMP words of one input (slot, session) to the UMP sink and the monitor; returns
 * the packets counted (the driver threads call it) */
int sa_midi_deliver_ump(int slot, uint32_t session, const uint32_t* words, int n, int64_t t);
/* the words of the UMP packet starting with word w (by its message type) */
int sa_ump_words(uint32_t w);

#if defined(_WIN32)
/* Windows MIDI Services (striso_midi_wms.cpp) */
typedef struct {
    char id[256], name[256];
} sa_wms_endpoint;
int sa_wms_init(void); /* 1: there (its service and SDK), 0: not (sa_wms_status says why) */
void sa_wms_shutdown(void);
const char* sa_wms_status(void);
void sa_wms_diagnostic(int on); /* tests: list the diagnostic loopback's B too */
int sa_wms_enumerate(sa_wms_endpoint* out, int max);
int sa_wms_open(const char* id, int slot, uint32_t session);
void sa_wms_close(int slot);
int sa_wms_test_source(char* id_out, int max);
int sa_wms_test_send(const uint32_t* words, int n);
#endif
int sa_midi_internal_has_sink(void);

#endif
