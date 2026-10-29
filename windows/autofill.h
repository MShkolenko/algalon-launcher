// Password autofill for the game login screen (docs/saved-login.md). Runs on its own thread, so the key patch loop and
// the guard in wWinMain never wait for it. The account is not typed: it is prefilled through SET accountName, and with
// a remembered account the login screen opens with the focus in the password field. The password is typed only after
// a positive check that the focused field is masked:
//   - two probe characters of very different width ('W', then 'i') are typed and each is captured from the screen;
//     only pixels that changed against the frame before the probe AND stay still across two captures after it count,
//     which drops the animated background and the blinking caret;
//   - a masked field draws the same glyph for both: the two changed boxes have the same width and height, sit on one
//     row, the second right of the first; a clear field draws a wide W and a narrow i;
//   - the probes are erased with two Backspaces and the erase is checked the same way.
// While probing and typing, low-level hooks swallow physical keyboard input and mouse buttons (injected events pass),
// so a click or Tab cannot move the focus mid-way; the game must stay the foreground window before every character.
// Any doubt means no password is typed and the player types it. Enter is never pressed. If the player starts a login
// by hand (Connection.log), autofill stops.
#pragma once
#include <windows.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

namespace autofill {

using Log = void (*)(const wchar_t* text);

struct Job {
    DWORD pid = 0;
    std::wstring password;      // wiped by the thread when it ends
    std::wstring conn_log;      // the client's Logs\Connection.log
    std::wstring debug_dir;     // non-empty: save probe frames there (calibration; never a frame with the password)
    Log log = nullptr;
};

// ---- input guard: low-level hooks on their own thread with a message loop --------------------------------------

static std::atomic<bool> g_guard{false};
static std::atomic<int> g_foreign{0};
static DWORD g_hook_thread = 0;

static LRESULT CALLBACK kb_hook(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && g_guard.load()) {
        auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(l);
        if (!(k->flags & LLKHF_INJECTED)) {
            g_foreign.fetch_add(1);
            return 1;  // swallowed: the game never sees it
        }
    }
    return CallNextHookEx(nullptr, code, w, l);
}

static LRESULT CALLBACK mouse_hook(int code, WPARAM w, LPARAM l) {
    if (code == HC_ACTION && g_guard.load() && w != WM_MOUSEMOVE) {
        auto* m = reinterpret_cast<MSLLHOOKSTRUCT*>(l);
        if (!(m->flags & LLMHF_INJECTED)) {
            g_foreign.fetch_add(1);
            return 1;
        }
    }
    return CallNextHookEx(nullptr, code, w, l);
}

static bool start_hooks() {
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::atomic<bool> ok{false};
    std::thread([&] {
        g_hook_thread = GetCurrentThreadId();
        HHOOK kb = SetWindowsHookExW(WH_KEYBOARD_LL, kb_hook, GetModuleHandleW(nullptr), 0);
        HHOOK ms = SetWindowsHookExW(WH_MOUSE_LL, mouse_hook, GetModuleHandleW(nullptr), 0);
        ok = kb && ms;
        SetEvent(ready);
        MSG msg;
        while (GetMessageW(&msg, nullptr, 0, 0) > 0) DispatchMessageW(&msg);
        if (kb) UnhookWindowsHookEx(kb);
        if (ms) UnhookWindowsHookEx(ms);
    }).detach();
    WaitForSingleObject(ready, 5000);
    CloseHandle(ready);
    return ok.load();
}

static void stop_hooks() {
    g_guard = false;
    if (g_hook_thread) PostThreadMessageW(g_hook_thread, WM_QUIT, 0, 0);
}

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

struct Frame {
    int w = 0, h = 0;
    std::vector<unsigned char> px;  // BGRA, top-down
};

// Screen copy of the window's client area (borderless/windowed DirectX goes through the compositor, so BitBlt of the
// screen sees it; a window that is not on top would show whatever covers it, which the foreground check rules out).
static bool grab(HWND h, Frame& f) {
    RECT r;
    POINT o{0, 0};
    if (!GetClientRect(h, &r) || !ClientToScreen(h, &o)) return false;
    f.w = r.right; f.h = r.bottom;
    if (f.w < 640 || f.h < 480) return false;
    HDC screen = GetDC(nullptr), mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateCompatibleBitmap(screen, f.w, f.h);
    HGDIOBJ old = SelectObject(mem, bmp);
    bool ok = BitBlt(mem, 0, 0, f.w, f.h, screen, o.x, o.y, SRCCOPY) != 0;
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = f.w;
    bi.bmiHeader.biHeight = -f.h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    f.px.assign(static_cast<size_t>(f.w) * f.h * 4, 0);
    ok = ok && GetDIBits(mem, bmp, 0, f.h, f.px.data(), &bi, DIB_RGB_COLORS) == f.h;
    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
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

static void save_bmp(const std::wstring& path, const Frame& f) {
    FILE* out = _wfopen(path.c_str(), L"wb");
    if (!out) return;
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

static bool send_char(wchar_t c) {
    INPUT in[2] = {};
    for (int k = 0; k < 2; ++k) {
        in[k].type = INPUT_KEYBOARD;
        in[k].ki.wScan = c;
        in[k].ki.dwFlags = KEYEVENTF_UNICODE | (k ? KEYEVENTF_KEYUP : 0);
    }
    return SendInput(2, in, sizeof(INPUT)) == 2;
}

static bool send_vk(WORD vk) {
    INPUT in[2] = {};
    for (int k = 0; k < 2; ++k) {
        in[k].type = INPUT_KEYBOARD;
        in[k].ki.wVk = vk;
        in[k].ki.dwFlags = k ? KEYEVENTF_KEYUP : 0;
    }
    return SendInput(2, in, sizeof(INPUT)) == 2;
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

enum class Probe { masked, clear, unclear, interrupted };

static const wchar_t* probe_name(Probe p) {
    return p == Probe::masked ? L"masked" : p == Probe::clear ? L"clear" : p == Probe::unclear ? L"unclear" : L"interrupted";
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

// Type one character, wait, capture twice; the settled change against `before`.
static bool step(HWND h, wchar_t c, WORD vk, const Frame& before, Frame& after, Box& box) {
    if (GetForegroundWindow() != h) return false;
    if (!(c ? send_char(c) : send_vk(vk))) return false;
    Sleep(350);
    Frame a;
    if (!grab(h, a)) return false;
    Sleep(250);
    if (!grab(h, after)) return false;
    box = settled_change(before, a, after);
    return box.n >= 0;
}

static Probe probe(const Job& job, HWND h, int attempt) {
    Frame f0, f1, f2, f3;
    Box b1, b2, b3;
    int foreign = g_foreign.load();
    if (!grab(h, f0)) return Probe::unclear;
    bool typed1 = step(h, L'W', 0, f0, f1, b1);
    bool typed2 = typed1 && step(h, L'i', 0, f1, f2, b2);
    // erase what was typed, then check the screen settled back to the frame before the probe in the probe's area
    int erase = typed1 + typed2;
    for (int k = 0; k < erase; ++k) {
        if (GetForegroundWindow() != h) break;
        send_vk(VK_BACK);
        Sleep(120);
    }
    Sleep(400);
    Frame g1, g2;
    bool erased = grab(h, g1) && (Sleep(250), grab(h, g2));
    if (erased) b3 = settled_change(f0, g1, g2);
    if (!job.debug_dir.empty()) {
        std::wstring p = job.debug_dir + L"\\probe" + std::to_wstring(attempt) + L"_";
        save_bmp(p + L"0.bmp", f0);
        if (typed1) save_bmp(p + L"1.bmp", f1);
        if (typed2) save_bmp(p + L"2.bmp", f2);
        if (erased) save_bmp(p + L"3.bmp", g2);
    }
    sayf(job, L"autofill: probe %d: W box %dx%d at %d,%d (%ld px); i box %dx%d at %d,%d (%ld px); after erase %ld px",
         attempt, b1.empty() ? 0 : b1.w(), b1.empty() ? 0 : b1.h(), b1.x0, b1.y0, b1.n, b2.empty() ? 0 : b2.w(),
         b2.empty() ? 0 : b2.h(), b2.x0, b2.y0, b2.n, erased ? b3.n : -1L);
    if (g_foreign.load() != foreign) return Probe::interrupted;
    if (!typed2 || !erased || b1.empty() || b2.empty()) return Probe::unclear;
    int limit = f0.h / 20;  // a glyph is far smaller than 1/20 of the window height
    if (b1.w() > limit || b1.h() > limit || b2.w() > limit || b2.h() > limit) return Probe::unclear;
    if (b3.n > b1.n / 4) return Probe::unclear;  // the erase did not bring the field back
    bool same_row = abs(b1.y0 - b2.y0) <= 2 && abs(b1.y1 - b2.y1) <= 2;
    bool right_of = b2.x0 >= b1.x0 + b1.w() / 2;
    if (!same_row || !right_of) return Probe::unclear;
    int dw = abs(b1.w() - b2.w());
    if (dw <= 2 + b1.w() / 10 && abs(b1.h() - b2.h()) <= 2) return Probe::masked;
    if (b1.w() >= 2 * b2.w()) return Probe::clear;  // W is far wider than i in any proportional font
    return Probe::unclear;
}

// ---- the thread --------------------------------------------------------------------------------------------------

static void wipe(std::wstring& s) {
    if (!s.empty()) SecureZeroMemory(&s[0], s.size() * sizeof(wchar_t));
    s.clear();
}

static void run(Job job) {
    ULONGLONG t0 = GetTickCount64();
    auto elapsed = [&] { return (GetTickCount64() - t0) / 1000; };
    auto gave_up = [&](const wchar_t* why) {
        sayf(job, L"autofill: not filled (%s); type the password in the game", why);
        stop_hooks();
        wipe(job.password);
    };
    HWND h = nullptr;
    while (!h && elapsed() < 120) {
        Sleep(500);
        h = game_window(job.pid);
    }
    if (!h) return gave_up(L"no game window");
    // the login screen: the client logs this line when its login UI asks for a launcher account
    while (!text_in(job.conn_log, "Launcher account state") && elapsed() < 180) Sleep(500);
    Sleep(3000);
    if (!start_hooks()) return gave_up(L"input hooks unavailable");
    for (int attempt = 1; attempt <= 6 && elapsed() < 240; ++attempt) {
        if (text_in(job.conn_log, "Glue login started")) return gave_up(L"a login was started by hand");
        if (!IsWindow(h)) return gave_up(L"the game window closed");
        if (GetForegroundWindow() != h) {
            Sleep(1000);
            --attempt;
            continue;
        }
        g_guard = true;
        Probe p = probe(job, h, attempt);
        if (p == Probe::clear) {
            g_guard = false;
            return gave_up(L"the focused field shows plain text, not the password field");
        }
        if (p != Probe::masked) {
            g_guard = false;
            sayf(job, L"autofill: probe %d %s, retrying", attempt, probe_name(p));
            Sleep(2000);
            continue;
        }
        // masked field confirmed: type the password, the game must stay in front for every character
        size_t typed = 0;
        for (wchar_t c : job.password) {
            if (GetForegroundWindow() != h || !send_char(c)) break;
            ++typed;
            Sleep(25);
        }
        Sleep(200);
        g_guard = false;
        if (typed != job.password.size()) {
            // the game lost the front: erase what went into the field (focus is still the masked field, input was held)
            for (size_t k = 0; k < typed && GetForegroundWindow() == h; ++k) send_vk(VK_BACK);
            return gave_up(L"the game window lost the focus while typing");
        }
        sayf(job, L"autofill: password filled (%zu characters) after %llu s; press Log In in the game", typed,
             (unsigned long long)elapsed());
        stop_hooks();
        wipe(job.password);
        return;
    }
    gave_up(L"the password field could not be confirmed");
}

// Starts the thread; the caller's copy of the password should be wiped after this returns.
inline void start(Job job) {
    std::thread(run, std::move(job)).detach();
}

}  // namespace autofill
