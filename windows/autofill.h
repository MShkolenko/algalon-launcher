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

// A password that is wiped whenever its holder goes away, on every path (taking it over wipes the source).
struct SecretString {
    std::wstring s;
    SecretString() = default;
    SecretString(const SecretString&) = delete;
    SecretString& operator=(const SecretString&) = delete;
    SecretString(SecretString&& o) : s(o.s) { o.wipe(); }  // copy, then wipe: a move may leave short (SSO) text behind
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
    int w() const { return x1 - x0 + 1; }
    int h() const { return y1 - y0 + 1; }
};

// Changed pixels between two frames of the same size (empty when the sizes differ).
static std::vector<unsigned char> changed(const Frame& a, const Frame& b) {
    std::vector<unsigned char> m;
    if (a.w != b.w || a.h != b.h) return m;
    m.assign(static_cast<size_t>(a.w) * a.h, 0);
    for (size_t p = 0; p < m.size(); ++p) m[p] = dist(a, b, p * 4) > 60;
    return m;
}

// Small 8-connected blobs of changed pixels: candidate glyphs (with the caret beside them). Big areas and specks
// (the animated background, embers) are dropped.
static std::vector<Box> blobs(const std::vector<unsigned char>& m, int w, int h) {
    std::vector<Box> out;
    if (m.empty()) return out;
    std::vector<unsigned char> seen(m.size(), 0);
    std::vector<int> stack;
    int maxsz = h / 30;
    for (int start = 0; start < w * h; ++start) {
        if (!m[start] || seen[start]) continue;
        Box b;
        stack.assign(1, start);
        seen[start] = 1;
        while (!stack.empty()) {
            int p = stack.back();
            stack.pop_back();
            int x = p % w, y = p / w;
            ++b.n;
            if (x < b.x0) b.x0 = x;
            if (x > b.x1) b.x1 = x;
            if (y < b.y0) b.y0 = y;
            if (y > b.y1) b.y1 = y;
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    int q = ny * w + nx;
                    if (m[q] && !seen[q]) {
                        seen[q] = 1;
                        stack.push_back(q);
                    }
                }
        }
        if (b.n >= 6 && b.w() >= 2 && b.h() >= 2 && b.w() <= maxsz && b.h() <= maxsz) out.push_back(b);
    }
    return out;
}

// Caret positions in a band of rows: centres of runs of columns whose changed pixels cover 85% of the band height
// (the caret is a full-height bar; glyphs are not).
static std::vector<int> caret_runs(const std::vector<unsigned char>& m, int w, int y0, int y1, int x0, int x1) {
    std::vector<int> runs;
    if (m.empty()) return runs;
    x0 = x0 < 0 ? 0 : x0;
    x1 = x1 >= w ? w - 1 : x1;
    int need = (y1 - y0 + 1) * 85 / 100, start = -1;
    for (int x = x0; x <= x1 + 1; ++x) {
        int n = 0;
        if (x <= x1)
            for (int y = y0; y <= y1; ++y) n += m[static_cast<size_t>(y) * w + x];
        bool tall = x <= x1 && n >= need;
        if (tall && start < 0) start = x;
        if (!tall && start >= 0) {
            runs.push_back((start + x - 1) / 2);
            start = -1;
        }
    }
    return runs;
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

// After a key: give the game a frame or two, then capture.
static bool observe(HWND h, Frame& after) {
    Sleep(180);
    return grab(h, after);
}

// The caret is the ruler. Typing W then i into an empty field moves the caret by the width of each glyph: in a masked
// field both are the same '*', in a clear field W is far wider than i. Calibrated live on 70658 (2026-10-29, 1920x1200
// RDP window): caret at 1219, after W 1231, after i 1243, back at 1219 after two Backspaces; one glyph blob per key.
// unsafe: something that was sent may sit where it was not meant to be; autofill must stop, not retry.
static Probe probe(const Job& job, HWND h, int attempt) {
    Frame f0, f1, f2, g;
    if (!grab(h, f0)) return Probe::unclear;
    int sent = 0;
    bool seen1 = false, seen2 = false, half = false;
    if (can_type(h)) {
        UINT n = send_char(L'W');
        half = n == 1;
        if (n == 2) {
            ++sent;
            seen1 = observe(h, f1);
            if (seen1 && can_type(h)) {
                n = send_char(L'i');
                half = n == 1;
                if (n == 2) {
                    ++sent;
                    seen2 = observe(h, f2);
                }
            }
        }
    }
    if (half) return Probe::unsafe;  // half a key went out: its effect is unknown, nothing more is sent
    // erase exactly what was sent (if a field took the keys, they are in it; if none did, the Backspaces go nowhere)
    bool erased_all = true;
    for (int k = 0; k < sent; ++k) {
        if (!can_type(h) || send_vk(VK_BACK) != 2) {
            erased_all = false;
            break;
        }
        Sleep(60);
    }
    bool seen3 = erased_all && observe(h, g);
    if (!job.debug_dir.empty() && seen2) {
        std::wstring p = job.debug_dir + L"\\probe" + std::to_wstring(attempt) + L"_";
        save_bmp(p + L"0.bmp", f0);
        save_bmp(p + L"1.bmp", f1);
        save_bmp(p + L"2.bmp", f2);
        if (seen3) save_bmp(p + L"3.bmp", g);
    }
    if (g_foreign.load() != 0 || !erased_all) return Probe::unsafe;
    if (sent < 2 || !seen2 || !seen3) return sent ? Probe::unsafe : Probe::unclear;
    int w = f0.w, hh = f0.h;
    auto m01 = changed(f0, f1), m12 = changed(f1, f2), m23 = changed(f2, g);
    if (m01.empty() || m12.empty() || m23.empty()) return Probe::unsafe;  // the window changed size mid-probe
    // the one pair: a blob from the W, and a blob from the i on the same row just right of it
    std::vector<Box> b1 = blobs(m01, w, hh), b2 = blobs(m12, w, hh);
    int pairs = 0;
    Box c1, c2;
    for (const Box& a : b1)
        for (const Box& b : b2) {
            int reach = 3 * (a.w() > a.h() ? a.w() : a.h());
            if (abs(a.y0 - b.y0) <= 3 && abs(a.y1 - b.y1) <= 3 && b.x0 >= a.x1 - 2 && b.x0 <= a.x1 + reach) {
                ++pairs;
                c1 = a;
                c2 = b;
            }
        }
    if (pairs != 1) {
        sayf(job, L"autofill: probe %d: %d candidate glyph pairs (%zu and %zu blobs), not on the login field yet",
             attempt, pairs, b1.size(), b2.size());
        return Probe::unclear;  // nothing took the keys (no login screen yet), or too much moved to tell
    }
    int y0 = c1.y0 < c2.y0 ? c1.y0 : c2.y0, y1 = c1.y1 > c2.y1 ? c1.y1 : c2.y1, band = y1 - y0 + 1;
    int lo = c1.x0 - 3 * band, hi = c2.x1 + 3 * band;
    std::vector<int> r12 = caret_runs(m12, w, y0, y1, lo, hi), r23 = caret_runs(m23, w, y0, y1, lo, hi);
    sayf(job, L"autofill: probe %d: glyph pair at %d,%d and %d,%d (rows %d-%d); caret runs after i %zu, after erase %zu",
         attempt, c1.x0, c1.y0, c2.x0, c2.y0, y0, y1, r12.size(), r23.size());
    // after the i the old caret goes and a new one appears: two runs; after the erase the caret at the end goes and
    // the one at the start appears: two runs, the right one where the i left the caret
    if (r12.size() != 2 || r23.size() != 2 || abs(r23[1] - r12[1]) > 1) return Probe::unsafe;
    if (!box_is_game(h, c1) || !box_is_game(h, c2)) return Probe::unsafe;
    int x0 = r23[0], x1 = r12[0], x2 = r12[1];
    int adv1 = x1 - x0, adv2 = x2 - x1;
    sayf(job, L"autofill: probe %d: caret %d -> %d -> %d, advances %d and %d", attempt, x0, x1, x2, adv1, adv2);
    if (adv1 < 3 || adv2 < 3) return Probe::unsafe;
    // the erase brought the field back: right of the start caret, the band matches the frame before the probe
    long long sum = 0, cnt = 0;
    for (int y = y0; y <= y1; ++y)
        for (int x = x0 + 3; x <= x2 + adv2; ++x) {
            if (x < 0 || x >= w) continue;
            sum += dist(f0, g, (static_cast<size_t>(y) * w + x) * 4);
            ++cnt;
        }
    int rest = cnt ? static_cast<int>(sum / cnt) : 999;
    if (rest > 30) {
        sayf(job, L"autofill: probe %d: the field did not come back empty after the erase (distance %d)", attempt, rest);
        return Probe::unsafe;
    }
    if (abs(adv1 - adv2) <= 1) return Probe::masked;  // the same glyph twice: '*'
    if (adv1 * 2 >= adv2 * 3) return Probe::clear;   // W much wider than i: the text is shown as typed
    return Probe::unsafe;
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
    // No log tells when the login screen is up (the client writes its logs only on exit), so the probe itself is the
    // readiness test: until a field takes the probe W, nothing changes on screen and it is tried again a second later.
    Sleep(1000);
    Hooks hooks;
    if (!hooks.start()) return gave_up(L"input hooks unavailable");
    int unclear = 0;
    for (int attempt = 1; elapsed() < 240; ++attempt) {
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
            if (++unclear > 150) break;
            if (job.debug_dir.empty() && attempt > 3) {
                Sleep(700);  // quiet: the log only names the first attempts unless debugging
                continue;
            }
            sayf(job, L"autofill: probe %d %s, retrying", attempt, probe_name(p));
            Sleep(700);
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
        sayf(job, L"autofill: password filled (%zu characters) %llu s after the launcher started the game, on probe "
                  L"%d; press Log In in the game", typed, (unsigned long long)elapsed(), attempt);
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
