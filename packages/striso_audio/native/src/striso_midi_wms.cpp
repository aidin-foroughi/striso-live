// striso_midi's MIDI 2.0 side on Windows: Windows MIDI Services (the in-box MIDI 2.0 service of
// Windows 11, midisrv, and its client SDK Windows.Devices.Midi2). UMP-native endpoints (MIDI 2.0
// devices) are listed next to WinMM's MIDI 1.0 inputs; their Universal MIDI Packets go from the
// service's callback thread, untouched, to striso_midi's UMP delivery (the sink: sv_ump_write).
//
// The SDK's implementation (Windows.Devices.Midi2.dll) is app-local, next to the exe: C++/WinRT
// finds an activation factory there when the class is not registered (its reg-free fallback), and
// an in-box copy (once Windows ships one) is used when it is. Without the service or the DLL there
// is no MIDI 2.0 here (sa_wms_init says why) and MIDI 1.0 goes through WinMM as before.
//
// Every SDK call runs on one thread of its own in the multi-threaded apartment (the caller may be
// an STA thread, e.g. Flutter's). That thread lives as long as the process: C++/WinRT caches the
// SDK's activation factories, which an apartment torn down and made again would leave dangling.

#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Midi2.h>
#include <winrt/Windows.Devices.Midi2.Enumeration.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

extern "C" {
#include "sa_midi_internal.h"
#include "sa_platform.h"
#include "striso_midi.h"
}

using namespace winrt;
using namespace winrt::Windows::Devices::Midi2;
using namespace winrt::Windows::Devices::Midi2::Enumeration;

namespace {

struct Worker {
    std::thread t;
    std::mutex m;
    std::condition_variable cv;
    std::deque<std::function<void()>> q;

    bool started = false;
    void start() {
        if (started) return;
        started = true;
        t = std::thread([this] {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            for (;;) {
                std::function<void()> f;
                {
                    std::unique_lock<std::mutex> l(m);
                    cv.wait(l, [this] { return !q.empty(); });
                    f = std::move(q.front());
                    q.pop_front();
                }
                f();
            }
        });
        t.detach();
    }
    // runs f on the worker and waits for it
    void run(std::function<void()> f) {
        std::mutex dm;
        std::condition_variable dcv;
        bool done = false;
        {
            std::lock_guard<std::mutex> l(m);
            q.push_back([&] {
                f();
                std::lock_guard<std::mutex> l2(dm);
                done = true;
                dcv.notify_one();
            });
        }
        cv.notify_one();
        std::unique_lock<std::mutex> l(dm);
        dcv.wait(l, [&] { return done; });
    }
};

struct Conn {
    MidiEndpointConnection c{nullptr};
    winrt::event_token token{};
};

// never destroyed: its thread runs until the process ends
Worker& g_worker = *new Worker();
bool g_on = false;
std::string g_why = "not started";
MidiSession g_session{nullptr};
Conn g_conn[SA_MIDI_MAX];
int g_diagnostic = 0;
// tests: the loopback's sending side
MidiEndpointConnection g_test_out{nullptr};

std::string utf8(hstring const& s) {
    const int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    std::string out((size_t)(n > 0 ? n : 0), '\0');
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}

hstring wide(const char* s) {
    const int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w((size_t)(n > 0 ? n - 1 : 0), L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, w.data(), n);
    return hstring(w);
}

const char* kPrefix = "ump:";

}  // namespace

// the SDK's DLL may sit next to this library rather than next to the exe (tests run from dart.exe):
// its folder joins the DLL search path that C++/WinRT's fallback uses
static void search_next_to_this_library(void) {
    static bool done = false;
    if (done) return;
    done = true;
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)&search_next_to_this_library, &self)) return;
    wchar_t path[MAX_PATH];
    const DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash) return;
    *slash = 0;
    AddDllDirectory(path);
}

extern "C" int sa_wms_init(void) {
    if (g_on) return 1;
    search_next_to_this_library();
    g_worker.start();
    g_worker.run([] {
        try {
            g_session = MidiSession::Create(L"Striso Live");
            g_on = g_session != nullptr;
            g_why = g_on ? "" : "Windows MIDI Services did not open a session";
        } catch (hresult_error const& e) {
            g_on = false;
            g_why = "Windows MIDI Services is not available (" + utf8(e.message()) + ")";
        } catch (...) {
            g_on = false;
            g_why = "Windows MIDI Services is not available";
        }
    });
    return g_on ? 1 : 0;
}

extern "C" const char* sa_wms_status(void) { return g_why.c_str(); }

extern "C" void sa_wms_shutdown(void) {
    if (!g_on) return;
    g_worker.run([] {
        try {
            for (auto& k : g_conn) {
                if (k.c) {
                    k.c.MessageReceived(k.token);
                    g_session.DisconnectEndpointConnection(k.c.ConnectionId());
                    k.c = nullptr;
                }
            }
            if (g_test_out) {
                g_session.DisconnectEndpointConnection(g_test_out.ConnectionId());
                g_test_out = nullptr;
            }
            g_session.Close();
        } catch (...) {
        }
        g_session = nullptr;
    });
    g_on = false;
    g_why = "not started";
}

extern "C" void sa_wms_diagnostic(int on) { g_diagnostic = on; }

extern "C" int sa_wms_enumerate(sa_wms_endpoint* out, int max) {
    if (!g_on) return 0;
    int k = 0;
    g_worker.run([&] {
        try {
            auto f = MidiEndpointDeviceInformationFilters::StandardNativeUniversalMidiPacketFormat;
            if (g_diagnostic) f = f | MidiEndpointDeviceInformationFilters::DiagnosticLoopback;
            for (auto const& e : MidiEndpointDeviceInformation::FindAll(MidiEndpointDeviceInformationSortOrder::Name, f)) {
                if (k >= max) break;
                // the diagnostic loopback's A side only sends into B: B is the input
                if (e.EndpointPurpose() == MidiEndpointDevicePurpose::DiagnosticLoopback && utf8(e.EndpointDeviceId()).find("loopback_b") == std::string::npos) {
                    continue;
                }
                const std::string id = kPrefix + utf8(e.EndpointDeviceId());
                const std::string name = utf8(e.Name());
                if (id.size() >= sizeof(out[k].id)) continue;
                strncpy(out[k].id, id.c_str(), sizeof(out[k].id) - 1);
                out[k].id[sizeof(out[k].id) - 1] = 0;
                strncpy(out[k].name, name.empty() ? "MIDI 2.0 endpoint" : name.c_str(), sizeof(out[k].name) - 1);
                out[k].name[sizeof(out[k].name) - 1] = 0;
                k++;
            }
        } catch (...) {
        }
    });
    return k;
}

extern "C" int sa_wms_open(const char* id, int slot, uint32_t session) {
    if (!g_on || slot < 0 || slot >= SA_MIDI_MAX || strncmp(id, kPrefix, strlen(kPrefix)) != 0) return SA_ERR_NOT_FOUND;
    int32_t r = SA_ERR_MIDI_OPEN;
    g_worker.run([&] {
        try {
            Conn& k = g_conn[slot];
            if (k.c) {
                k.c.MessageReceived(k.token);
                g_session.DisconnectEndpointConnection(k.c.ConnectionId());
                k.c = nullptr;
            }
            auto c = g_session.CreateEndpointConnection(wide(id + strlen(kPrefix)));
            if (!c) {
                r = SA_ERR_NOT_FOUND;
                return;
            }
            k.token = c.MessageReceived([slot, session](IMidiMessageReceivedEventSource const&, MidiMessageReceivedEventArgs const& args) {
                uint32_t w[4] = {0, 0, 0, 0};
                const uint8_t n = args.FillWords(w[0], w[1], w[2], w[3]);
                if (n > 0 && n <= 4) sa_midi_deliver_ump(slot, session, w, n, (int64_t)sa_now_us64());
            });
            if (!c.Open()) {
                c.MessageReceived(k.token);
                g_session.DisconnectEndpointConnection(c.ConnectionId());
                return;
            }
            k.c = c;
            r = SA_OK;
        } catch (...) {
            r = SA_ERR_MIDI_OPEN;
        }
    });
    return r;
}

extern "C" void sa_wms_close(int slot) {
    if (!g_on || slot < 0 || slot >= SA_MIDI_MAX) return;
    g_worker.run([slot] {
        try {
            Conn& k = g_conn[slot];
            if (!k.c) return;
            k.c.MessageReceived(k.token);
            g_session.DisconnectEndpointConnection(k.c.ConnectionId());
            k.c = nullptr;
        } catch (...) {
        }
    });
}

// tests: the diagnostic loopback (Service Test Loopback A sends, B receives): the id of B as an
// input, and A opened to send
extern "C" int sa_wms_test_source(char* id_out, int max) {
    if (!g_on) return SA_ERR_MIDI_SYSTEM;
    int32_t r = SA_ERR_NOT_FOUND;
    g_worker.run([&] {
        try {
            hstring a, b;
            for (auto const& e : MidiEndpointDeviceInformation::FindAll(MidiEndpointDeviceInformationSortOrder::Name, MidiEndpointDeviceInformationFilters::DiagnosticLoopback)) {
                const std::string s = utf8(e.EndpointDeviceId());
                if (s.find("loopback_a") != std::string::npos) a = e.EndpointDeviceId();
                if (s.find("loopback_b") != std::string::npos) b = e.EndpointDeviceId();
            }
            if (a.empty() || b.empty()) return;
            if (!g_test_out) {
                g_test_out = g_session.CreateEndpointConnection(a);
                if (!g_test_out || !g_test_out.Open()) {
                    g_test_out = nullptr;
                    r = SA_ERR_MIDI_OPEN;
                    return;
                }
            }
            const std::string id = kPrefix + utf8(b);
            if ((int)id.size() >= max) return;
            strcpy(id_out, id.c_str());
            r = SA_OK;
        } catch (...) {
            r = SA_ERR_MIDI_OPEN;
        }
    });
    return r;
}

extern "C" int sa_wms_test_send(const uint32_t* words, int n) {
    if (!g_on || !g_test_out) return SA_ERR_NOT_FOUND;
    int32_t r = SA_OK;
    g_worker.run([&] {
        try {
            const auto res = g_test_out.SendMultipleMessagesWordArray(0, 0, (uint32_t)n, array_view<uint32_t const>(words, words + n));
            if ((static_cast<uint32_t>(res) & 0x80000000u) == 0) r = SA_ERR_MIDI_OPEN;
        } catch (...) {
            r = SA_ERR_MIDI_OPEN;
        }
    });
    return r;
}
