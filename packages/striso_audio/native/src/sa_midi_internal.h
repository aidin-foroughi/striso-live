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
int sa_midi_internal_has_sink(void);

#endif
