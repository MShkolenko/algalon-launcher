// Password autofill for the game login screen (docs/saved-login.md). Runs on its own thread, so the key patch loop and
// the guard in wWinMain never wait for it. The account is not typed: it is prefilled through SET accountName, and with
// a remembered account the login screen opens with the focus in the password field. The password is typed only after
// a check that the focused field is masked:
//   - two probe characters of very different shape ('W', then 'i') are typed and each is captured from the screen;
//     only pixels that changed against the frame before the probe AND stay still across two captures after it count,
//     which drops the animated background and the blinking caret;
//   - a masked field draws the same glyph for both: the two changed boxes have the same size, sit on one row, the
//     second right of the first, and their pixels match; a clear field draws a W and an i, which differ in pixels even
//     in a monospaced font;
//   - the probes are erased with two Backspaces and the erase is checked the same way.
// While probing and typing, low-level hooks swallow every keyboard event and mouse button that is not ours (ours carry
// AUTOFILL_TAG in dwExtraInfo), and any such event stops the fill; the game must be the foreground window, the input
// desktop must be the normal one and no modifier may be held before every character.
// Known limit, accepted by the operator (2026-10-29): this is evidence from the screen, not a field-level interface of
// the client; if the game moved its own focus between the probe and the typing, the password would follow it. The
// login screen has no reason to, but it cannot be proven from outside. Test with a fictional password first.
// Any doubt means no password is typed and the player types it. Enter is never pressed. If the player starts a login
// by hand (Connection.log, which the launcher deletes before the client starts, so it holds only this run), autofill
// stops.
#pragma once
#include <windows.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace autofill {

using Log = void (*)(const wchar_t* text);

// A password that is wiped whenever its holder goes away, on every path (a move wipes the source).
struct SecretString {
    std::wstring s;
    SecretString() = default;
    SecretString(const SecretString&) = delete;
    SecretString& operator=(const SecretString&) = delete;
    SecretString(SecretString&& o) noexcept : s(std::move(o.s)) { o.wipe(); }
    void wipe() {
        if (!s.empty()) SecureZeroMemory(&s[0], s.size() * sizeof(wchar_t));
        s.clear();
    }
    ~SecretString() { wipe(); }
};

struct Job {
    DWORD pid = 0;
    SecretString password;
    std::wstring conn_log;      // the client's Logs\Connection.log
    std::wstring debug_dir;     // non-empty: save probe frames there (calibration; never a frame with the password)
    Log log = nullptr;
};

static const ULONG_PTR AUTOFILL_TAG = 0x41464C31;  // "AFL1": marks the launcher's own injected events

// ---- input guard: low-level hooks on their own thread with a message loop --------------------------------------

static std::atomic<bool> g_guard{false};
static std::atomic<int> g_foreign{0};

static LRESULT CALLBACK kb_hook(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && g_guard.load()) {
        auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(l);
        if (k->dwExtraInfo != AUTOFILL_TAG) {
            g_foreign.fetch_add(1);
            return 1;  // swallowed: the game never sees it
        }
    }
    return CallNextHookEx(nullptr, code, w, l);
}

static LRESULT CALLBACK mouse_hook(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && g_guard.load() && w != WM_MOUSEMOVE) {
        g_foreign.fetch_add(1);  // no mouse event of ours exists
        return 1;
    }
    return CallNextHookEx(nullptr, code, w, l);
}

// The hook thread and its state belong to one Hooks object; the destructor stops and joins the thread.
class Hooks {
public:
    bool start() {
        auto st = state_;
        thread_ = std::thread([st] {
            MSG msg;
            PeekMessageW(&msg, nullptr, WM_USER, WM_USER, PM_NOREMOVE);  // the queue exists before ready is signalled
            st->tid = GetCurrentThreadId();
            HHOOK kb = SetWindowsHookExW(WH_KEYBOARD_LL, kb_hook, GetModuleHandleW(nullptr), 0);
            HHOOK ms = kb ? SetWindowsHookExW(WH_MOUSE_LL, mouse_hook, GetModuleHandleW(nullptr), 0) : nullptr;
            st->ok = kb && ms;
            st->ready = true;
            if (st->ok)
                while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
            if (kb) UnhookWindowsHookEx(kb);
            if (ms) UnhookWindowsHookEx(ms);
            st->exited = true;
        });
        for (int i = 0; i < 500 && !state_->ready.load(); ++i) Sleep(10);  // the thread owns no local of ours
        return state_->ready.load() && state_->ok.load();
    }
    ~Hooks() {
        g_guard = false;
        if (!thread_.joinable()) return;
        while (!state_->ready.load()) Sleep(10);  // it signals ready on every path; then the quit can be delivered
        if (state_->ok.load())
            while (!state_->exited.load() && !PostThreadMessageW(state_->tid.load(), WM_QUIT, 0, 0)) Sleep(10);
        thread_.join();
    }

private:
    struct State {
        std::atomic<bool> ready{false}, ok{false}, exited{false};
        std::atomic<DWORD> tid{0};
    };
    std::shared_ptr<State> state_ = std::make_shared<State>();
    std::thread thread_;
};

// ---- the game window and the screen ------------------------------------------------------------------------------

struct Found { DWORD pid; HWND hwnd; LONG area; };

static BOOL CALLBACK enum_cb(HWND h, LPARAM p) {
    auto* f = reinterpret_cast<Found*>(p);
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    RECT r;
    if (pid == f->pid && IsWindowVisible(h) && GetClientRect(h, &r)) {
        LONG a = (r.right - r.left) * (r.bottom - r.top);
        if (a > f->area) { f->area = a; f->hwnd = h; }
    }
    return TRUE;
}

static HWND game_window(DWORD pid) {
    Found f{pid, nullptr, 0};
    EnumWindows(enum_cb, reinterpret_cast<LPARAM>(&f));
    return f.area >= 640 * 480 ? f.hwnd : nullptr;
}

// The normal desktop takes input (not the secure desktop of Ctrl+Alt+Del or a lock screen).
static bool input_desktop_normal() {
    HDESK d = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!d) return false;
    wchar_t name[64] = {};
    DWORD need = 0;
    bool ok = GetUserObjectInformationW(d, UOI_NAME, name, sizeof(name), &need) && _wcsicmp(name, L"Default") == 0;
    CloseDesktop(d);
    return ok;
}

static bool modifiers_up() {
    const int keys[] = {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN};
    for (int k : keys)
        if (GetAsyncKeyState(k) & 0x8000) return false;
    return true;
}

// Everything that must hold before one key goes out.
static bool can_type(HWND h) {
    return GetForegroundWindow() == h && input_desktop_normal() && modifiers_up() && g_foreign.load() == 0;
}

struct Frame {
    int w = 0, h = 0;
    std::vector<unsigned char> px;  // BGRA, top-down
};

// Screen copy of the window's client area (borderless/windowed DirectX goes through the compositor, so BitBlt of the
// screen sees it). A window covering part of the game would be captured instead; the probe checks that the changed
// area belongs to the game window.
static bool grab(HWND h, Frame& f) {
    RECT r;
    POINT o{0, 0};
    if (!GetClientRect(h, &r) || !ClientToScreen(h, &o)) return false;
    f.w = r.right; f.h = r.bottom;
    if (f.w < 640 || f.h < 480) return false;
    f.px.assign(static_cast<size_t>(f.w) * f.h * 4, 0);  // before any GDI handle: a throw here leaks nothing
    bool ok = false;
    HDC screen = GetDC(nullptr);
    if (!screen) return false;
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp = mem ? CreateCompatibleBitmap(screen, f.w, f.h) : nullptr;
    if (bmp) {
        HGDIOBJ old = SelectObject(mem, bmp);
        ok = old && BitBlt(mem, 0, 0, f.w, f.h, screen, o.x, o.y, SRCCOPY) != 0;
        if (old) SelectObject(mem, old);  // GetDIBits needs the bitmap out of the DC
        if (ok) {
            BITMAPINFO bi = {};
            bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
            bi.bmiHeader.biWidth = f.w;
            bi.bmiHeader.biHeight = -f.h;
            bi.bmiHeader.biPlanes = 1;
            bi.bmiHeader.biBitCount = 32;
            ok = GetDIBits(mem, bmp, 0, f.h, f.px.data(), &bi, DIB_RGB_COLORS) == f.h;
        }
        DeleteObject(bmp);
    }
    if (mem) DeleteDC(mem);
    ReleaseDC(nullptr, screen);
    return ok;
}

static int dist(const Frame& a, const Frame& b, size_t i) {
    return abs(a.px[i] - b.px[i]) + abs(a.px[i + 1] - b.px[i + 1]) + abs(a.px[i + 2] - b.px[i + 2]);
}

struct Box {
    int x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
    long n = 0;
    bool empty() const { return n == 0; }
    int w() const { return x1 - x0 + 1; }
    int h() const { return y1 - y0 + 1; }
};

// Pixels that differ from `before` in both later captures and are equal between them: what input drew and left.
// n == -1: the frames cannot be compared.
static Box settled_change(const Frame& before, const Frame& a, const Frame& b) {
    Box box;
    if (before.w != a.w || a.w != b.w || before.h != a.h || a.h != b.h) { box.n = -1; return box; }
    for (int y = 0; y < a.h; ++y)
        for (int x = 0; x < a.w; ++x) {
            size_t i = (static_cast<size_t>(y) * a.w + x) * 4;
            if (dist(before, a, i) > 60 && dist(before, b, i) > 60 && dist(a, b, i) < 12) {
                ++box.n;
                if (x < box.x0) box.x0 = x;
                if (x > box.x1) box.x1 = x;
                if (y < box.y0) box.y0 = y;
                if (y > box.y1) box.y1 = y;
            }
        }
    return box;
}

// Mean colour distance between the box `p` in `fp` and the box `q` in `fq`, aligned at their top-left corners;
// the boxes must be the same size. Small for two copies of one glyph, large for a W against an i.
static int patch_distance(const Frame& fp, const Box& p, const Frame& fq, const Box& q) {
    long long sum = 0;
    for (int y = 0; y < p.h(); ++y)
        for (int x = 0; x < p.w(); ++x) {
            size_t i = (static_cast<size_t>(p.y0 + y) * fp.w + p.x0 + x) * 4;
            size_t j = (static_cast<size_t>(q.y0 + y) * fq.w + q.x0 + x) * 4;
            for (int c = 0; c < 3; ++c) sum += abs(fp.px[i + c] - fq.px[j + c]);
        }
    return static_cast<int>(sum / (static_cast<long long>(p.w()) * p.h()));
}

static bool box_is_game(HWND h, const Box& b) {
    POINT c{(b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2};
    if (!ClientToScreen(h, &c)) return false;
    HWND at = WindowFromPoint(c);
    return at && GetAncestor(at, GA_ROOT) == GetAncestor(h, GA_ROOT);
}

static void save_bmp(const std::wstring& path, const Frame& f) {
    FILE* out = nullptr;
    if (_wfopen_s(&out, path.c_str(), L"wb") != 0 || !out) return;
    BITMAPFILEHEADER fh = {};
    BITMAPINFOHEADER ih = {};
    ih.biSize = sizeof(ih); ih.biWidth = f.w; ih.biHeight = -f.h; ih.biPlanes = 1; ih.biBitCount = 32;
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(ih);
    fh.bfSize = fh.bfOffBits + static_cast<DWORD>(f.px.size());
    fwrite(&fh, sizeof(fh), 1, out);
    fwrite(&ih, sizeof(ih), 1, out);
    fwrite(f.px.data(), 1, f.px.size(), out);
    fclose(out);
}

// ---- keys --------------------------------------------------------------------------------------------------------

// How many of the 2 events (down, up) went out: 0 none, 1 half a key (its effect unknown), 2 a whole key.
static UINT send_char(wchar_t c) {
    INPUT in[2] = {};
    for (int k = 0; k < 2; ++k) {
        in[k].type = INPUT_KEYBOARD;
        in[k].ki.wScan = c;
        in[k].ki.dwFlags = KEYEVENTF_UNICODE | (k ? KEYEVENTF_KEYUP : 0);
        in[k].ki.dwExtraInfo = AUTOFILL_TAG;
    }
    return SendInput(2, in, sizeof(INPUT));
}

static UINT send_vk(WORD vk) {
    INPUT in[2] = {};
    for (int k = 0; k < 2; ++k) {
        in[k].type = INPUT_KEYBOARD;
        in[k].ki.wVk = vk;
        in[k].ki.dwFlags = k ? KEYEVENTF_KEYUP : 0;
        in[k].ki.dwExtraInfo = AUTOFILL_TAG;
    }
    return SendInput(2, in, sizeof(INPUT));
}

static bool text_in(const std::wstring& path, const char* needle) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::string data;
    char buf[65536];
    DWORD got = 0;
    while (ReadFile(h, buf, sizeof(buf), &got, nullptr) && got) data.append(buf, got);
    CloseHandle(h);
    return data.find(needle) != std::string::npos;
}

// ---- the probe ---------------------------------------------------------------------------------------------------

enum class Probe { masked, clear, unclear, unsafe };

static const wchar_t* probe_name(Probe p) {
    return p == Probe::masked ? L"masked" : p == Probe::clear ? L"clear" : p == Probe::unclear ? L"unclear" : L"unsafe";
}

static void sayf(const Job& job, const wchar_t* fmt, ...) {
    if (!job.log) return;
    wchar_t buf[512];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, ap);
    va_end(ap);
    job.log(buf);
}

// Wait, capture twice, the settled change against `before`.
static bool observe(HWND h, const Frame& before, Frame& after, Box& box) {
    Sleep(350);
    Frame a;
    if (!grab(h, a)) return false;
    Sleep(250);
    if (!grab(h, after)) return false;
    box = settled_change(before, a, after);
    return box.n >= 0;
}

// unsafe: something that was sent may sit where it was not meant to be; autofill must stop, not retry.
static Probe probe(const Job& job, HWND h, int attempt) {
    Frame f0, f1, f2, g;
    Box b1, b2, b3;
    if (!grab(h, f0)) return Probe::unclear;
    int sent = 0;
    bool seen1 = false, seen2 = false, half = false;
    if (can_type(h)) {
        UINT n = send_char(L'W');
        half = n == 1;
        if (n == 2) {
            ++sent;
            seen1 = observe(h, f0, f1, b1);
            if (seen1 && can_type(h)) {
                n = send_char(L'i');
                half = n == 1;
                if (n == 2) {
                    ++sent;
                    seen2 = observe(h, f1, f2, b2);
                }
            }
        }
    }
    if (half) return Probe::unsafe;  // half a key went out: its effect is unknown, nothing more is sent
    // erase exactly what was sent, then check the screen came back to the frame before the probe
    bool erased_all = true;
    for (int k = 0; k < sent; ++k) {
        if (!can_type(h) || send_vk(VK_BACK) != 2) { erased_all = false; break; }
        Sleep(120);
    }
    bool settled = erased_all && observe(h, f0, g, b3) && b3.n >= 0;
    if (!job.debug_dir.empty()) {
        std::wstring p = job.debug_dir + L"\\probe" + std::to_wstring(attempt) + L"_";
        save_bmp(p + L"0.bmp", f0);
        if (seen1) save_bmp(p + L"1.bmp", f1);
        if (seen2) save_bmp(p + L"2.bmp", f2);
        if (settled) save_bmp(p + L"3.bmp", g);
    }
    sayf(job, L"autofill: probe %d: sent %d; W box %dx%d at %d,%d (%ld px); i box %dx%d at %d,%d (%ld px); "
              L"after erase %ld px", attempt, sent, b1.empty() ? 0 : b1.w(), b1.empty() ? 0 : b1.h(), b1.x0, b1.y0,
         b1.n, b2.empty() ? 0 : b2.w(), b2.empty() ? 0 : b2.h(), b2.x0, b2.y0, b2.n, settled ? b3.n : -1L);
    if (g_foreign.load() != 0 || !erased_all) return Probe::unsafe;
    if (sent < 2 || !seen2 || !settled || b1.empty() || b2.empty()) return sent ? Probe::unsafe : Probe::unclear;
    if (b3.n > b1.n / 4) return Probe::unsafe;  // the erase did not bring the field back
    int limit = f0.h / 40;  // a login field glyph is far smaller than 1/40 of the window height
    if (b1.w() > limit || b1.h() > limit || b2.w() > limit || b2.h() > limit) return Probe::unclear;
    if (!box_is_game(h, b1) || !box_is_game(h, b2)) return Probe::unclear;
    bool same_row = abs(b1.y0 - b2.y0) <= 2 && abs(b1.y1 - b2.y1) <= 2;
    bool right_of = b2.x0 >= b1.x1 - 1;
    if (!same_row || !right_of) return Probe::unclear;
    if (b1.w() == b2.w() && b1.h() == b2.h()) {
        int d = patch_distance(f1, b1, f2, b2);
        sayf(job, L"autofill: probe %d: same size, pixel distance %d", attempt, d);
        if (d <= 24) return Probe::masked;  // two copies of one glyph
        return Probe::clear;                // same size, different pixels: a monospaced clear field
    }
    return Probe::clear;  // different sizes: W and i drawn as themselves
}

// ---- the thread --------------------------------------------------------------------------------------------------

static void run(Job& job) {
    struct Wipe {
        SecretString& p;
        ~Wipe() { p.wipe(); }
    } wipe{job.password};
    ULONGLONG t0 = GetTickCount64();
    auto elapsed = [&] { return (GetTickCount64() - t0) / 1000; };
    auto gave_up = [&](const wchar_t* why) { sayf(job, L"autofill: not filled (%s); type the password in the game", why); };
    HWND h = nullptr;
    while (!h && elapsed() < 120) {
        Sleep(500);
        h = game_window(job.pid);
    }
    if (!h) return gave_up(L"no game window");
    // the login screen: the client logs this line when its login UI asks for a launcher account
    while (!text_in(job.conn_log, "Launcher account state") && elapsed() < 180) Sleep(500);
    if (!text_in(job.conn_log, "Launcher account state")) return gave_up(L"the login screen was not seen in the log");
    Sleep(3000);
    Hooks hooks;
    if (!hooks.start()) return gave_up(L"input hooks unavailable");
    for (int attempt = 1; attempt <= 6 && elapsed() < 240; ++attempt) {
        if (text_in(job.conn_log, "Glue login started")) return gave_up(L"a login was started by hand");
        if (!IsWindow(h)) return gave_up(L"the game window closed");
        if (GetForegroundWindow() != h || !input_desktop_normal()) {
            Sleep(1000);
            --attempt;
            continue;
        }
        g_foreign = 0;
        g_guard = true;
        Probe p = probe(job, h, attempt);
        if (p == Probe::clear || p == Probe::unsafe) {
            g_guard = false;
            return gave_up(p == Probe::clear ? L"the focused field shows plain text, not the password field"
                                             : L"the probe was interrupted or could not be erased cleanly; check the "
                                               L"login fields for stray W/i characters");
        }
        if (p != Probe::masked) {
            g_guard = false;
            sayf(job, L"autofill: probe %d %s, retrying", attempt, probe_name(p));
            Sleep(2000);
            continue;
        }
        if (text_in(job.conn_log, "Glue login started")) return gave_up(L"a login was started by hand");
        // masked field confirmed: type the password; every check holds before every character
        size_t typed = 0;
        for (wchar_t c : job.password.s) {
            if (!can_type(h) || send_char(c) != 2) break;
            ++typed;
            Sleep(25);
        }
        Sleep(200);
        g_guard = false;
        if (typed != job.password.s.size()) {
            // no blind cleanup: where the focus is now is not known
            sayf(job, L"autofill: stopped after %zu of %zu characters (the game lost the front, the desktop changed, "
                      L"a key was held or other input came); clear the password field and type it yourself",
                 typed, job.password.s.size());
            return;
        }
        sayf(job, L"autofill: password filled (%zu characters) after %llu s; press Log In in the game", typed,
             (unsigned long long)elapsed());
        return;
    }
    gave_up(L"the password field could not be confirmed");
}

// Starts the thread; the caller wipes its own copy of the password after this returns. Never throws: autofill must
// not take the launcher down with it.
inline void start(Job job) {
    try {
        auto owned = std::make_shared<Job>(std::move(job));
        std::thread([owned] {
            try {
                run(*owned);
            } catch (...) {
                owned->password.wipe();
                if (owned->log) owned->log(L"autofill: internal error; type the password in the game");
            }
            g_guard = false;
        }).detach();
    } catch (...) {  // `owned` wipes the password as it goes away; `job` was wiped by the move or is wiped here
        job.password.wipe();
        if (job.log) job.log(L"autofill: could not start; type the password in the game");
    }
}

}  // namespace autofill
