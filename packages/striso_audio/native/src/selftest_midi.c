/* The self-test's MIDI part: the parser, sa_midi_inject through the sink and the monitor, a sink
 * swap while another thread injects, and listing the system's inputs (enumeration only: nothing
 * is opened). Runs without a MIDI device. */
#include "sa_core.h"
#include "sa_midi_internal.h"
#include "sa_platform.h"
#include "striso_midi.h"

#include <stdio.h>
#include <string.h>

static void (*say)(const char* fmt, ...);
static void (*check)(int ok, const char* what);

static void hex(const uint8_t* b, int n, char* out, int size) {
    int k = 0;
    out[0] = 0;
    for (int i = 0; i < n && k < size - 4; i++) k += snprintf(out + k, (size_t)(size - k), "%s%02X", i ? " " : "", b[i]);
}

/* bytes in, the expected packets out (a parser fresh for each case unless keep) */
static void parse_case(const char* what, const uint8_t* in, int n, const uint8_t* want, int nwant) {
    sa_midi_parser p;
    sa_midi_parser_reset(&p);
    uint8_t out[64 * 4];
    int used = 0;
    const int k = sa_midi_parse(&p, in, n, out, 64, &used);
    char got[400], exp[400], line[1000];
    hex(out, 4 * k, got, sizeof(got));
    hex(want, nwant, exp, sizeof(exp));
    snprintf(line, sizeof(line), "midi parser: %s -> [%s]%s", what, got, (4 * k == nwant && memcmp(out, want, (size_t)nwant) == 0) ? "" : " (expected another)");
    check(4 * k == nwant && memcmp(out, want, (size_t)nwant) == 0 && used == n, line);
    if (!(4 * k == nwant && memcmp(out, want, (size_t)nwant) == 0)) say("      expected [%s]\n", exp);
}

#define CASE(what, IN, WANT)                                                   \
    do {                                                                       \
        static const uint8_t in_[] = IN;                                       \
        static const uint8_t want_[] = WANT;                                   \
        parse_case(what, in_, (int)sizeof(in_), want_, (int)sizeof(want_) - 1); \
    } while (0)
/* WANT ends with a dummy byte so that an empty expectation is still an array */
#define B(...) {__VA_ARGS__}

static void test_parser(void) {
    CASE("note on, running status", B(0x90, 0x3C, 0x64, 0x3E, 0x50), B(0x09, 0x90, 0x3C, 0x64, 0x09, 0x90, 0x3E, 0x50, 0));
    CASE("clock inside a message", B(0x90, 0x3C, 0xF8, 0x64, 0xFE), B(0x09, 0x90, 0x3C, 0x64, 0));
    CASE("real time only (F8 FE FA FC FF)", B(0xF8, 0xFE, 0xFA, 0xFC, 0xFF), B(0));
    CASE("sysex skipped", B(0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7, 0xB0, 0x07, 0x7F), B(0x0B, 0xB0, 0x07, 0x7F, 0));
    CASE("sysex cancels running status", B(0x90, 0x3C, 0x64, 0xF0, 0x01, 0x02, 0xF7, 0x3E, 0x50), B(0x09, 0x90, 0x3C, 0x64, 0));
    CASE("sysex ended by a status", B(0xF0, 0x01, 0x02, 0x80, 0x3C, 0x00), B(0x08, 0x80, 0x3C, 0x00, 0));
    CASE("note on velocity 0 kept", B(0x91, 0x3C, 0x00), B(0x09, 0x91, 0x3C, 0x00, 0));
    CASE("2-byte: program change, channel pressure (CIN C, D)", B(0xC5, 0x10, 0xD3, 0x40, 0x41), B(0x0C, 0xC5, 0x10, 0x00, 0x0D, 0xD3, 0x40, 0x00, 0x0D, 0xD3, 0x41, 0x00, 0));
    CASE("3-byte: off, poly pressure, control, bend (CIN 8, A, B, E)", B(0x80, 0x3C, 0x00, 0xA2, 0x3C, 0x20, 0xBF, 0x4A, 0x40, 0xEF, 0x00, 0x40),
         B(0x08, 0x80, 0x3C, 0x00, 0x0A, 0xA2, 0x3C, 0x20, 0x0B, 0xBF, 0x4A, 0x40, 0x0E, 0xEF, 0x00, 0x40, 0));
    CASE("system common swallows its data (F2 F1 F3 F6)", B(0xF2, 0x10, 0x20, 0xF1, 0x05, 0xF3, 0x01, 0xF6, 0x3C), B(0));
    CASE("data without a status dropped", B(0x3C, 0x64, 0xE0, 0x00, 0x40), B(0x0E, 0xE0, 0x00, 0x40, 0));
    CASE("a status cuts a message short", B(0x90, 0x3C, 0xB0, 0x40, 0x7F), B(0x0B, 0xB0, 0x40, 0x7F, 0));

    /* a message split over three deliveries, and a full output buffer (the rest on the next call) */
    sa_midi_parser p;
    sa_midi_parser_reset(&p);
    uint8_t out[8 * 4];
    static const uint8_t a[] = {0x9F}, b[] = {0x40}, c[] = {0x7F, 0x41};
    int k = sa_midi_parse(&p, a, 1, out, 8, NULL);
    k += sa_midi_parse(&p, b, 1, out, 8, NULL);
    const int k3 = sa_midi_parse(&p, c, 2, out, 8, NULL);
    check(k == 0 && k3 == 1 && out[0] == 0x09 && out[1] == 0x9F && out[2] == 0x40 && out[3] == 0x7F && p.have == 1, "midi parser: a message split over three reads");
    uint8_t many[3 * 10], one[4 * 4];
    for (int i = 0; i < 10; i++) {
        many[3 * i] = 0xB0;
        many[3 * i + 1] = (uint8_t)i;
        many[3 * i + 2] = 0x11;
    }
    sa_midi_parser_reset(&p);
    int used = 0, got = 0, ok = 1;
    const uint8_t* q = many;
    int left = (int)sizeof(many);
    while (left > 0) {
        const int n = sa_midi_parse(&p, q, left, one, 4, &used);
        for (int j = 0; j < n; j++) ok = ok && one[4 * j] == 0x0B && one[4 * j + 2] == (uint8_t)(got + j);
        got += n;
        q += used;
        left -= used;
        if (n == 0) break;
    }
    check(ok && got == 10, "midi parser: an output of 4 packets takes 10 messages in 3 calls, none lost");
}

/* ---------------------------------------------------------------- inject, sink, monitor */

static int sink_take(uint8_t* out, int max) { return sa_midi_test_sink_read(out, max); }

static void test_inject(void) {
    uint8_t junk[4096];
    while (sink_take(junk, sizeof(junk)) > 0) {}
    sa_midi_event ev[64];
    while (sa_midi_events(ev, 64) > 0) {}
    const uint32_t lost0 = sa_midi_events_lost();

    sa_midi_set_sink(sa_midi_test_sink, NULL);
    static const uint8_t in[] = {0x90, 0x3C, 0x64, 0xF8, 0x3E, 0x00, 0xF0, 0x01, 0x02, 0xF7, 0xD0, 0x22, 0xE1, 0x00, 0x48, 0xFE};
    static const uint8_t want[] = {0x09, 0x90, 0x3C, 0x64, 0x09, 0x90, 0x3E, 0x00, 0x0D, 0xD0, 0x22, 0x00, 0x0E, 0xE1, 0x00, 0x48};
    const int64_t t0 = sa_clock_us();
    const int32_t r = sa_midi_inject("selftest-a", in, (int32_t)sizeof(in));
    const int64_t t1 = sa_clock_us();
    uint8_t got[256];
    const int n = sink_take(got, sizeof(got));
    char g[400], line[600];
    hex(got, n, g, sizeof(g));
    snprintf(line, sizeof(line), "midi inject: the sink gets exactly [%s]", g);
    check(r == 4 && n == (int)sizeof(want) && memcmp(got, want, sizeof(want)) == 0, line);

    /* the device it made: listed, virtual, open, counted */
    int found = -1;
    sa_midi_device d;
    for (int i = 0; i < sa_midi_count(); i++)
        if (sa_midi_get(i, &d) == SA_OK && strcmp(d.id, "selftest-a") == 0) {
            found = i;
            break;
        }
    check(found >= 0 && d.is_virtual && d.open && d.present && d.messages == 4 && d.last_us >= t0 && d.last_us <= t1 && sa_midi_sizeof_device() == 552 &&
              sa_midi_sizeof_event() == 16,
          "midi inject: a virtual device of that id, open, 4 messages, its time on sa_clock_us; struct sizes 552 and 16");

    /* the monitor: the same 4 messages, oldest first, with the device's slot */
    const int ne = sa_midi_events(ev, 64);
    int ok = ne == 4;
    for (int i = 0; ok && i < 4; i++) {
        const uint8_t* w = want + 4 * i;
        ok = ev[i].device == d.slot && ev[i].len == (w[0] == 0x0D ? 2 : 3) && ev[i].bytes[0] == w[1] && ev[i].bytes[1] == w[2] && ev[i].bytes[2] == w[3] &&
             ev[i].t_us >= t0 && ev[i].t_us <= t1;
    }
    check(ok && sa_midi_events(ev, 64) == 0, "midi monitor: 4 events, oldest first, slot, length and bytes as sent; read once");

    /* a second device keeps its own running status */
    static const uint8_t a1[] = {0x92, 0x40}, b1[] = {0x93, 0x41, 0x10}, a2[] = {0x7F};
    sa_midi_inject("selftest-a", a1, 2);
    sa_midi_inject("selftest-b", b1, 3);
    sa_midi_inject("selftest-a", a2, 1);
    const int n2 = sink_take(got, sizeof(got));
    check(n2 == 8 && got[1] == 0x93 && got[2] == 0x41 && got[5] == 0x92 && got[6] == 0x40 && got[7] == 0x7F, "midi inject: two devices, a message of one split around the other's");
    while (sa_midi_events(ev, 64) > 0) {}

    /* no sink: still counted and monitored */
    sa_midi_set_sink(NULL, NULL);
    static const uint8_t c1[] = {0xB0, 0x01, 0x02};
    sa_midi_inject("selftest-a", c1, 3);
    check(sink_take(got, sizeof(got)) == 0 && sa_midi_events(ev, 64) == 1, "midi: without a sink, monitored but not delivered");

    /* the ring when nobody reads it: drops the newest, counts them */
    uint8_t burst[3 * 256];
    for (int i = 0; i < 256; i++) {
        burst[3 * i] = 0xA0;
        burst[3 * i + 1] = (uint8_t)(i & 0x7F);
        burst[3 * i + 2] = 0x10;
    }
    int sent = 0;
    while (sent < SA_MIDI_RING + 100) {
        sa_midi_inject("selftest-a", burst, (int32_t)sizeof(burst));
        sent += 256;
    }
    int total = 0, k;
    static sa_midi_event big[SA_MIDI_RING];
    k = sa_midi_events(big, SA_MIDI_RING);
    total += k;
    while ((k = sa_midi_events(ev, 64)) > 0) total += k;
    const uint32_t lost = sa_midi_events_lost() - lost0;
    snprintf(line, sizeof(line), "midi monitor: %d sent with nobody reading: %d kept (the oldest), %u dropped", sent, total, lost);
    check(total == SA_MIDI_RING && lost == (uint32_t)(sent - SA_MIDI_RING) && big[0].bytes[1] == 0, line);

    /* closing a virtual device forgets it */
    const int c0 = sa_midi_count();
    const int rc = sa_midi_close("selftest-a") + sa_midi_close("selftest-b");
    int still = 0;
    for (int i = 0; i < sa_midi_count(); i++)
        if (sa_midi_get(i, &d) == SA_OK && strncmp(d.id, "selftest-", 9) == 0) still = 1;
    check(rc == SA_OK && sa_midi_count() == c0 - 2 && !still && sa_midi_close("selftest-a") == SA_ERR_NOT_FOUND, "midi: closing a virtual device forgets it");
}

/* ---------------------------------------------------------------- sink swap under load */

static volatile uint32_t g_inside, g_calls, g_stop, g_injects;

static int32_t slow_sink(void* user, const uint8_t* packets, int32_t n) {
    (void)user;
    (void)packets;
    sa_st(&g_inside, 1);
    const uint64_t t = sa_now_us64();
    while (sa_now_us64() - t < 30) {} /* a sink that takes a while: 30 us */
    sa_inc(&g_calls);
    sa_st(&g_inside, 0);
    return n;
}

static void injector(void* arg) {
    (void)arg;
    static const uint8_t m[] = {0x90, 0x3C, 0x64};
    while (!sa_ld(&g_stop)) {
        sa_midi_inject("selftest-load", m, 3);
        sa_inc(&g_injects);
    }
}

static void test_swap(void) {
    sa_st(&g_stop, 0);
    sa_st(&g_calls, 0);
    sa_midi_set_sink(slow_sink, NULL);
    sa_thread th = sa_thread_start(injector, NULL);
    if (!th) {
        check(0, "midi sink swap: thread");
        return;
    }
    int bad = 0, rounds = 0;
    uint32_t total = 0;
    for (int r = 0; r < 20; r++) {
        sa_midi_set_sink(slow_sink, NULL);
        sa_sleep_ms(5);
        sa_midi_set_sink(NULL, NULL);
        const uint32_t inside = sa_ld(&g_inside), c = sa_ld(&g_calls);
        sa_sleep_ms(3);
        if (inside || sa_ld(&g_calls) != c) bad++;
        total = c;
        rounds++;
    }
    sa_st(&g_stop, 1);
    sa_thread_join(th);
    char line[300];
    snprintf(line, sizeof(line), "midi sink swap: %d detaches while another thread injects (%u injects, %u sink calls): none ran after a detach returned", rounds,
             sa_ld(&g_injects), total);
    check(bad == 0 && total > 20, line);
    sa_midi_close("selftest-load");
}

/* ---------------------------------------------------------------- the system's inputs */

static void test_system(void) {
    const int was = sa_midi_internal_inited();
    const int32_t r = sa_midi_init();
    if (r != SA_OK) {
        check(0, "midi: the system's MIDI set up");
        return;
    }
    const uint32_t g = sa_midi_refresh();
    const uint32_t g2 = sa_midi_refresh();
    int n = sa_midi_count(), opened = 0;
    sa_midi_device d;
    for (int i = 0; i < n; i++)
        if (sa_midi_get(i, &d) == SA_OK && d.open && !d.is_virtual) opened++;
    char line[300];
    snprintf(line, sizeof(line), "midi: the system's inputs listed (%d), none opened, the generation steady (%u)", n, g2);
    check(g == g2 && (was || opened == 0), line);
    for (int i = 0; i < n; i++)
        if (sa_midi_get(i, &d) == SA_OK) say("      %s  [id %s]%s\n", d.name, d.id, d.open ? "  open" : "");
    check(sa_midi_open("selftest: no such input") == SA_ERR_NOT_FOUND, "midi: opening an unknown id: not found");
    if (!was) sa_midi_shutdown();
}

/* MIDI 2.0: UMP words to the UMP sink untouched, counted by packet; a byte input still to the byte
 * sink only */
static void test_ump(void) {
    uint32_t got[64];
    uint8_t gotb[64];
    while (sa_midi_test_ump_sink_read(got, 64) > 0) {}
    while (sa_midi_test_sink_read(gotb, 64) > 0) {}
    sa_midi_set_ump_sink(sa_midi_test_ump_sink, NULL);
    sa_midi_set_sink(sa_midi_test_sink, NULL);
    /* channel pressure (2 words), a note-on (2 words), a utility NOOP (1 word), a 4-word stream message */
    static const uint32_t w[] = {0x40D10000, 0x8CCCCCCC, 0x40913E00, 0xB0000000, 0x00000000, 0xF0000000, 0x11223344, 0x55667788, 0x99AABBCC};
    const int k = sa_midi_inject_ump("selftest ump", w, 9);
    const int n = sa_midi_test_ump_sink_read(got, 64);
    const int nb = sa_midi_test_sink_read(gotb, 64);
    char line[200];
    snprintf(line, sizeof(line), "midi 2.0: inject: %d words untouched to the UMP sink, %d packets counted, none to the byte sink", n, k);
    check(n == 9 && memcmp(got, w, sizeof(w)) == 0 && k == 4 && nb == 0, line);
    sa_midi_device d;
    int proto = 0;
    for (int i = 0; i < sa_midi_count(); i++)
        if (sa_midi_get(i, &d) == SA_OK && strcmp(d.id, "selftest ump") == 0) proto = d.protocol;
    check(proto == 2, "midi 2.0: the injected device is listed as MIDI 2.0 (protocol 2)");
    static const uint8_t b[] = {0x90, 60, 100};
    sa_midi_inject("selftest bytes", b, 3);
    check(sa_midi_test_ump_sink_read(got, 64) == 0 && sa_midi_test_sink_read(gotb, 64) == 4, "midi 2.0: a MIDI 1.0 input still goes to the byte sink only");
    sa_midi_close("selftest ump");
    sa_midi_close("selftest bytes");
    sa_midi_set_ump_sink(NULL, NULL);
    sa_midi_set_sink(NULL, NULL);
}

/* MIDI 2.0 through the system: a MIDI 2.0 source of the system (macOS: a CoreMIDI virtual source;
 * Windows: Windows MIDI Services' diagnostic loopback) into an open input, the words untouched */
static void test_ump_system(void) {
    const int was = sa_midi_internal_inited();
    if (sa_midi_init() != SA_OK) {
        check(0, "midi 2.0: the system's MIDI set up");
        return;
    }
    char id[256], st[256];
    sa_midi2_status(st, sizeof(st));
    const int32_t r = sa_midi_test_ump_source(id, sizeof(id));
    if (r != SA_OK) {
        say("skip  midi 2.0 through the system: no MIDI 2.0 source here (%d%s%s)\n", r, st[0] ? ": " : "", st);
        if (!was) sa_midi_shutdown();
        return;
    }
    sa_midi_refresh();
    sa_midi_device d;
    int proto = 0;
    for (int i = 0; i < sa_midi_count(); i++)
        if (sa_midi_get(i, &d) == SA_OK && strcmp(d.id, id) == 0) proto = d.protocol;
    char line[600];
    snprintf(line, sizeof(line), "midi 2.0 through the system: the source is listed as MIDI 2.0 (%.200s)", id);
    check(proto == 2, line);
    uint32_t got[64];
    while (sa_midi_test_ump_sink_read(got, 64) > 0) {}
    sa_midi_set_ump_sink(sa_midi_test_ump_sink, NULL);
    const int32_t o = sa_midi_open(id);
    snprintf(line, sizeof(line), "midi 2.0 through the system: the input opens (%d)", o);
    check(o == SA_OK, line);
    static const uint32_t w[] = {0x40D10000, 0x8CCCCCCC, 0x40913E00, 0xB0000000, 0x40813E00, 0x50000000};
    const int32_t sent = sa_midi_test_ump_send(w, 6);
    int n = 0;
    for (int i = 0; i < 200 && n < 6; i++) {
        sa_sleep_ms(5);
        n += sa_midi_test_ump_sink_read(got + n, 64 - n);
    }
    snprintf(line, sizeof(line), "midi 2.0 through the system: sent (%d), %d words arrived untouched", sent, n);
    check(sent == SA_OK && n == 6 && memcmp(got, w, sizeof(w)) == 0, line);
    if (n) say("      got %08X %08X %08X %08X %08X %08X\n", got[0], got[1], n > 2 ? got[2] : 0, n > 3 ? got[3] : 0, n > 4 ? got[4] : 0, n > 5 ? got[5] : 0);
    sa_midi_close(id);
    sa_midi_set_ump_sink(NULL, NULL);
    if (!was) sa_midi_shutdown();
}

void sa_selftest_midi(void (*say_fn)(const char* fmt, ...), void (*check_fn)(int ok, const char* what)) {
    say = say_fn;
    check = check_fn;
    test_parser();
    if (sa_midi_internal_has_sink()) {
        check(0, "midi: a sink is set (the library is in use): inject and swap skipped");
    } else {
        test_inject();
        test_swap();
        test_ump();
    }
    test_system();
    if (!sa_midi_internal_has_sink()) test_ump_system();
}
