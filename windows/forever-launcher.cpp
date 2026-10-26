// Forever launcher: starts the WoW Forever client against one private realm. Windows only, Win32 API, statically
// linked: one small exe, nothing to install besides what it sets up itself. The scheme (operator, 2026-10-10):
//   - the client keeps its own portal suffix: portal "<portal>" becomes <portal>.actual.battle.net;
//   - one administrator prompt (only when something is missing) writes one hosts line pointing that name at our
//     server and puts the realm's own CA, name-constrained to <portal>.actual.battle.net only, into the
//     computer's trusted roots, so the server certificate validates;
//   - a separate settings file WTF\<config>.wtf carries the portal, the official Config.wtf is never touched, so
//     starting the game from Battle.net still goes to the official servers;
//   - while the client runs, the region group 8 key in its runtime key store is replaced with the server's public
//     key (the store appears when the player presses Login). The client image itself is never modified.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <tlhelp32.h>
#include <algorithm>
#include <cstdio>
#include <cstdarg>
#include <cstdint>
#include <string>
#include <vector>
#include <map>

// Everything that names one realm (server, portal, CA, names of its files and folders) comes from the profile the
// build was given: build.cmd <profile> puts windows/profiles/<profile> on the include path.
#include "profile.h"

typedef std::wstring wstr;

static const char* KNOWN_HEX[12] = {
    "9B0671C815DFF513BFD4A2B26AE1F84EC9106841B2FB620DB65F6ADE7C21AD06", "112451B9843C2799E4750AA3D9B9AFABF536A645B863C4ADB2078B932B354E04",
    "A6B858485748BF38BE193517AB90F8DE169EFF0989EA9360DB346A378B0FFE15", "50FFDEB807F8FF73A299A16000AA6575C5945BE875ADFC8795374ED3415249AC",
    "9F842D078755647C008E5FE3E12B839A981DE02A1F520CB2545CC04CD2323E0E", "B8CC75864D8EF461D8DD6AA7425E2C63C24D3982066B8D773A1549BFE24E05EE",
    "76BB7BBDD9F34E124A4573C3AA227E3C87CC603506697D054F6FDEC342E56EBF", "1FD6DD8FA0EC30D39E3F72E755B8A045BDE0F70449DC71008B767C2EAA89FB9F",
    "15D618BD7DB577BD9A8D45769C59E4FC631633BF447398A4B489B4C26FBC03AD", "B34EC592D2AC4993F5FFC85B15C3DA9078694051CB224345592AF7136D796C99",
    "9E91586DD4B115AB0568B21959E181F6545910BC5E2F30B8975CA09D7BC3EFCE", "769C824A1DADD19AEEFA420414D1732DAF44537F98AA229FC5477BCA55F9D59A"};
static const unsigned char FLAGS[12] = {1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1};
static const size_t ENTRY = 40, COUNT = 12;

// The realm's CA (profile.h): its nameConstraints must permit only <portal>.actual.battle.net. Its private key is
// never in the source or the launcher.
static const char CA_PEM[] = REALM_CA_PEM;

static const wchar_t* SUFFIX = L".actual.battle.net";
// The client: the release "WoW: Forever" (Battle.net product wowf) is _forever_\Wow.exe; the old beta
// (wow_classic_beta) was _classic_beta_\WowB.exe. launcher.ini naming a client that is not there falls back to the other.
// Note (2026-10-25): the release asks for region and language at EVERY start when the config has no locale, and its
// answer resets SET portal to the region (we logged in at the real EU.actual.battle.net). The settings file therefore
// always carries textLocale and audioLocale (see default_locale); with them the client keeps our portal.
static const wchar_t* DEF_EXE = L"_forever_\\Wow.exe";
static const wchar_t* KNOWN_EXES[] = {L"_forever_\\Wow.exe", L"_classic_beta_\\WowB.exe"};
// REALM_SERVER answers on 1120 (login), 8082 (REST) and 8090 (world). The hosts line gets the address it
// resolves to at launch time.
static const wchar_t* DEF_SERVER = REALM_SERVER;
static const wchar_t* DEF_PORTAL = REALM_PORTAL L":1120";
static const wchar_t* DEF_CONFIG = REALM_CONFIG;
static const wchar_t* DEF_KEY = L"02596F0D0C061A8B30745988FD72C59E29EC367FB0F341F28E0F08D037BAFC69";  // stock TrinityCore
static const int DEF_GROUP = 8;

static FILE* g_log = nullptr;

static void say(const wchar_t* fmt, ...) {
    wchar_t buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, 1024, _TRUNCATE, fmt, ap);
    va_end(ap);
    SYSTEMTIME t;
    GetLocalTime(&t);
    if (g_log) {  // no console window (GUI subsystem): progress goes only to launcher.log
        fwprintf(g_log, L"%02d:%02d:%02d %s\n", t.wHour, t.wMinute, t.wSecond, buf);
        fflush(g_log);
    }
}

static wstr g_logdir;  // %LOCALAPPDATA%\<realm long name>, or %TEMP%\<realm long name>

// `err` is passed by the caller from the failing call only; a logic error shows no stale Windows error code.
static int fail(const wchar_t* msg, DWORD err = 0) {
    wchar_t sys[512] = L"";
    if (err) FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, err, 0, sys, 512, nullptr);
    say(L"ERROR: %s (Windows error %lu %s)", msg, err, sys);
    wchar_t text[1600];
    if (err)
        _snwprintf_s(text, 1600, _TRUNCATE, L"%s\n\nWindows error %lu: %s\nDetails: %s\\launcher.log", msg, err, sys, g_logdir.c_str());
    else
        _snwprintf_s(text, 1600, _TRUNCATE, L"%s\n\nDetails: %s\\launcher.log", msg, g_logdir.c_str());
    MessageBoxW(nullptr, text, REALM_NAME L" launcher", MB_OK | MB_ICONERROR);
    return 1;
}

// Writable per-user place for launcher.ini and launcher.log: the exe itself may sit in Program Files or Downloads.
static wstr data_dir() {
    wchar_t base[MAX_PATH] = L"";
    wstr d;
    if (GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH)) d = wstr(base) + L"\\" REALM_LONG_NAME;
    if (d.empty() || (!CreateDirectoryW(d.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS)) {
        GetTempPathW(MAX_PATH, base);
        d = wstr(base) + REALM_LONG_NAME;
        CreateDirectoryW(d.c_str(), nullptr);
    }
    return d;
}

// ---- files and text -------------------------------------------------------------------------------------------

static bool exists(const wstr& p) { return GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES; }

static wstr dirname(const wstr& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == wstr::npos ? L"." : p.substr(0, i);
}

static bool read_file(const wstr& p, std::string& out) {
    HANDLE h = CreateFileW(p.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz;
    GetFileSizeEx(h, &sz);
    out.resize((size_t)sz.QuadPart);
    DWORD n = 0;
    bool ok = out.empty() || (ReadFile(h, &out[0], (DWORD)out.size(), &n, nullptr) && n == out.size());
    CloseHandle(h);
    return ok;
}

static bool write_file(const wstr& p, const std::string& data) {
    HANDLE h = CreateFileW(p.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD n = 0;
    bool ok = data.empty() || (WriteFile(h, data.data(), (DWORD)data.size(), &n, nullptr) && n == data.size());
    ok = FlushFileBuffers(h) && ok;
    CloseHandle(h);
    return ok;
}

// Our own files only (launcher.ini, WTF\<config>.wtf): write next to the target, then swap it in, so a failed write
// never leaves a half-written file. The hosts file never goes through here (see overwrite_in_place).
static bool write_atomic(const wstr& p, const std::string& data, bool /*unused*/) {
    wstr tmp = p + L".tmp-launcher";
    if (!write_file(tmp, data)) return false;
    bool ok = MoveFileExW(tmp.c_str(), p.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    if (!ok) DeleteFileW(tmp.c_str());
    return ok;
}

static wstr to_wide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
    wstr w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
    return w;
}

static std::string to_utf8(const wstr& w) {
    if (w.empty()) return "";
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

static wstr trim(const wstr& s) {
    size_t a = s.find_first_not_of(L" \t\r\n"), b = s.find_last_not_of(L" \t\r\n");
    return a == wstr::npos ? L"" : s.substr(a, b - a + 1);
}

static wstr lower(wstr s) {
    for (auto& c : s) c = towlower(c);
    return s;
}

static std::vector<wstr> lines_of(const wstr& text) {
    std::vector<wstr> out;
    size_t start = 0;
    while (start <= text.size()) {
        size_t nl = text.find(L'\n', start);
        if (nl == wstr::npos) nl = text.size();
        wstr line = text.substr(start, nl - start);
        if (!line.empty() && line.back() == L'\r') line.pop_back();
        out.push_back(line);
        start = nl + 1;
    }
    if (!out.empty() && out.back().empty()) out.pop_back();
    return out;
}

// ---- launcher.ini -----------------------------------------------------------------------------------------------

typedef std::map<wstr, wstr> Ini;

static Ini read_ini(const wstr& path) {
    Ini ini;
    std::string raw;
    if (!read_file(path, raw)) return ini;
    for (const wstr& line : lines_of(to_wide(raw))) {
        wstr l = trim(line);
        size_t eq = l.find(L'=');
        if (l.empty() || l[0] == L'#' || l[0] == L';' || eq == wstr::npos) continue;
        ini[trim(l.substr(0, eq))] = trim(l.substr(eq + 1));
    }
    return ini;
}

static bool write_ini(const wstr& path, const Ini& ini) {
    wstr text = L"# " REALM_ID L"-launcher settings. client = the World of Warcraft folder (the one that holds _forever_),\n"
                L"# server = the address " REALM_PORTAL L".actual.battle.net is pointed at in the hosts file.\n";
    for (const auto& kv : ini) text += kv.first + L"=" + kv.second + L"\n";
    return write_atomic(path, to_utf8(text), false);
}

static wstr ask_folder() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    BROWSEINFOW bi = {};
    bi.lpszTitle = L"Select the World of Warcraft folder (the one that contains _forever_ or _classic_beta_)";
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    wchar_t path[MAX_PATH] = L"";
    if (pidl) {
        SHGetPathFromIDListW(pidl, path);
        CoTaskMemFree(pidl);
    }
    return path;
}

// ---- server address ---------------------------------------------------------------------------------------------

// An IPv4 literal is used as is; a name is resolved to its first IPv4 address. Empty on failure.
static wstr resolve_ipv4(const wstr& name) {
    IN_ADDR probe;
    if (InetPtonW(AF_INET, name.c_str(), &probe) == 1) return name;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return L"";
    ADDRINFOW hints = {}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    wstr ip;
    if (GetAddrInfoW(name.c_str(), nullptr, &hints, &res) == 0 && res) {
        wchar_t buf[INET_ADDRSTRLEN];
        if (InetNtopW(AF_INET, &((sockaddr_in*)res->ai_addr)->sin_addr, buf, INET_ADDRSTRLEN)) ip = buf;
        FreeAddrInfoW(res);
    }
    WSACleanup();
    return ip;
}

// ---- hosts ------------------------------------------------------------------------------------------------------

static wstr hosts_path() {
    wchar_t sys[MAX_PATH];
    GetSystemDirectoryW(sys, MAX_PATH);
    return wstr(sys) + L"\\drivers\\etc\\hosts";
}

// The hosts file is handled as BYTES, never re-encoded (Codex review 2026-10-10: a forced UTF-8 round trip corrupts
// ANSI and UTF-16 hosts files). Entries are ASCII; every line that does not name our host is kept byte for byte.
// A UTF-16 or NUL-containing file is refused, not rewritten. Our host is removed as a TOKEN, so other names on the
// same line survive.

static std::string ascii_lower(std::string s) {
    for (auto& c : s) if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return s;
}

static std::string to_ascii(const wstr& w) {  // ip and host are validated ASCII before they get here
    std::string s;
    for (wchar_t c : w) s += (char)(c & 0x7F);
    return s;
}

static std::vector<std::string> split_ws(const std::string& s) {
    std::vector<std::string> out;
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t')) ++i;
        size_t j = i;
        while (j < s.size() && s[j] != ' ' && s[j] != '\t') ++j;
        if (j > i) out.push_back(s.substr(i, j - i));
        i = j;
    }
    return out;
}

// Encoding of a hosts file: 0 plain bytes (ANSI/ASCII), 1 UTF-8 with BOM (3 bytes kept), -1 refuse (UTF-16 or NULs).
static int hosts_encoding(const std::string& raw) {
    if (raw.size() >= 2 && (((unsigned char)raw[0] == 0xFF && (unsigned char)raw[1] == 0xFE) ||
                            ((unsigned char)raw[0] == 0xFE && (unsigned char)raw[1] == 0xFF)))
        return -1;
    if (raw.find('\0') != std::string::npos) return -1;
    if (raw.size() >= 3 && (unsigned char)raw[0] == 0xEF && (unsigned char)raw[1] == 0xBB && (unsigned char)raw[2] == 0xBF)
        return 1;
    return 0;
}

// Walks the lines; for each one naming `host` reports its address. Rebuilds the file into `out` without our host.
// Returns false only for an unsupported encoding.
static bool hosts_scan(const std::string& raw, const std::string& host, bool& right, bool& wrong, const std::string& ip,
                       std::string* out) {
    right = wrong = false;
    int enc = hosts_encoding(raw);
    if (enc < 0) return false;
    size_t start = enc == 1 ? 3 : 0;
    if (out) *out = raw.substr(0, start);
    std::string want = ascii_lower(host);
    while (start < raw.size()) {
        size_t nl = raw.find('\n', start);
        size_t end = nl == std::string::npos ? raw.size() : nl + 1;
        std::string line = raw.substr(start, end - start);  // keeps its own \r\n or \n
        start = end;
        std::string body = line;
        while (!body.empty() && (body.back() == '\n' || body.back() == '\r')) body.pop_back();
        std::string eol = line.substr(body.size());
        size_t hash = body.find('#');
        std::string content = body.substr(0, hash), comment = hash == std::string::npos ? "" : body.substr(hash);
        std::vector<std::string> tok = split_ws(content);
        bool ours = false;
        std::vector<std::string> keep;
        for (size_t i = 1; i < tok.size(); ++i) {
            if (ascii_lower(tok[i]) == want) ours = true;
            else keep.push_back(tok[i]);
        }
        if (!ours) {
            if (out) *out += line;  // untouched, byte for byte
            continue;
        }
        (tok[0] == ip ? right : wrong) = true;
        if (!out || keep.empty()) continue;  // only our host on the line: the line goes
        std::string rebuilt = tok[0];
        for (const auto& k : keep) rebuilt += " " + k;
        if (!comment.empty()) rebuilt += " " + comment;
        *out += rebuilt + (eol.empty() ? "\r\n" : eol);
    }
    return true;
}

// True when the hosts file maps `host` to exactly `ip` and to nothing else.
static bool hosts_ok(const wstr& ip, const wstr& host) {
    std::string raw;
    if (!read_file(hosts_path(), raw)) return false;
    bool right, wrong;
    return hosts_scan(raw, to_ascii(host), right, wrong, to_ascii(ip), nullptr) && right && !wrong;
}

// Whole-file read and in-place rewrite through ONE open handle (Codex round 3, 2026-10-10: reading, closing and
// reopening let another program change hosts in between, and our write would silently drop that change). The same
// file object is rewritten, so its ACL and attributes stay exactly as they were.
static bool handle_read_all(HANDLE h, std::string& out) {
    LARGE_INTEGER sz, zero = {};
    if (!GetFileSizeEx(h, &sz) || sz.QuadPart > (16 << 20) || !SetFilePointerEx(h, zero, nullptr, FILE_BEGIN)) return false;
    out.assign((size_t)sz.QuadPart, '\0');
    DWORD n = 0;
    return out.empty() || (ReadFile(h, &out[0], (DWORD)out.size(), &n, nullptr) && n == out.size());
}

static bool handle_write_all(HANDLE h, const std::string& data) {
    LARGE_INTEGER zero = {};
    if (!SetFilePointerEx(h, zero, nullptr, FILE_BEGIN)) return false;
    DWORD n = 0;
    bool ok = data.empty() || (WriteFile(h, data.data(), (DWORD)data.size(), &n, nullptr) && n == data.size());
    return ok && SetEndOfFile(h) && FlushFileBuffers(h);
}

// Still used by test_hosts.cpp to exercise an in-place rewrite on a scratch file.
static bool overwrite_in_place(const wstr& p, const std::string& data) {
    HANDLE h = CreateFileW(p.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    bool ok = handle_write_all(h, data);
    CloseHandle(h);
    return ok;
}

// Exit codes of the elevated helper, read by the normal launcher.
enum SetupCode { SETUP_OK = 0, SETUP_UNREADABLE = 2, SETUP_ENCODING = 3, SETUP_BACKUP = 4, SETUP_WRITE = 5,
                 SETUP_VERIFY = 6, SETUP_CA = 7, SETUP_ARGS = 8, SETUP_LOCK = 9, SETUP_RESTORE = 10 };

// Runs elevated. One handle with read+write access and NO write sharing is held from the first read to the final
// read-back, so no other program can change hosts in between; a machine-wide mutex also serializes launchers. The
// backup is verified before the first byte is written; a failed or mismatched write is undone through the same
// handle. Opening the file at all failing means it was never touched.
static int hosts_fix(const wstr& ip, const wstr& host) {
    HANDLE lock = CreateMutexW(nullptr, FALSE, L"Global\\" REALM_MUTEX_ID L"LauncherHostsEdit");
    if (!lock || WaitForSingleObject(lock, 30000) == WAIT_TIMEOUT) {
        if (lock) CloseHandle(lock);
        return SETUP_LOCK;
    }
    int rc = SETUP_OK;
    wstr path = hosts_path();
    std::string raw, rebuilt;
    bool right = false, wrong = false;
    bool present = exists(path);
    HANDLE h = INVALID_HANDLE_VALUE;
    bool writable = true;
    if (present) {
        h = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            // Read-only or locked for writing: it may already be correct (only the CA missing), so look before failing.
            writable = false;
            h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        }
        if (h == INVALID_HANDLE_VALUE) rc = SETUP_UNREADABLE;
        else if (!handle_read_all(h, raw)) rc = SETUP_UNREADABLE;     // never write over a file we could not read
    }
    if (rc == SETUP_OK && !hosts_scan(raw, to_ascii(host), right, wrong, to_ascii(ip), &rebuilt)) rc = SETUP_ENCODING;
    if (rc == SETUP_OK && !writable && !(right && !wrong)) rc = SETUP_WRITE;  // a change is needed but cannot be made
    if (rc == SETUP_OK && !(right && !wrong)) {
        if (!rebuilt.empty() && rebuilt.back() != '\n') rebuilt += "\r\n";
        rebuilt += to_ascii(ip) + " " + to_ascii(host) + "   # " REALM_LONG_NAME_A " realm (" REALM_ID_A "-launcher)\r\n";
        if (present) {
            SYSTEMTIME t;
            GetLocalTime(&t);
            wchar_t stamp[32];
            swprintf_s(stamp, L"%04d%02d%02d-%02d%02d%02d", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
            wstr bak = path + L".bak-" REALM_ID L"-" + stamp;
            std::string check, back;
            if (!write_file(bak, raw) || !read_file(bak, check) || check != raw) rc = SETUP_BACKUP;
            else if (!(handle_write_all(h, rebuilt) && handle_read_all(h, back) && back == rebuilt)) {
                // Started writing and something went wrong (disk full, antivirus): undo through the same handle.
                std::string restored;
                bool undone = handle_write_all(h, raw) && handle_read_all(h, restored) && restored == raw;
                rc = undone ? SETUP_VERIFY : SETUP_RESTORE;
            }
        } else if (!write_file(path, rebuilt)) {
            rc = SETUP_WRITE;
        }
    }
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (rc == SETUP_OK && !(right && !wrong)) {
        {
            STARTUPINFOW si = {sizeof(si)};
            PROCESS_INFORMATION pi = {};
            wchar_t cmd[] = L"ipconfig /flushdns";
            if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
                WaitForSingleObject(pi.hProcess, 10000);
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
        }
    }
    ReleaseMutex(lock);
    CloseHandle(lock);
    return rc;
}

static const wchar_t* setup_message(DWORD code) {
    switch (code) {
        case SETUP_UNREADABLE: return L"the hosts file could not be read (an antivirus may be holding it); nothing was changed";
        case SETUP_ENCODING: return L"the hosts file is in an unusual encoding (UTF-16); nothing was changed. Add the line by hand";
        case SETUP_BACKUP: return L"a backup of the hosts file could not be made; nothing was changed";
        case SETUP_WRITE: return L"the hosts file could not be written (read-only or locked by an antivirus); nothing was changed";
        case SETUP_VERIFY: return L"the hosts file did not read back as written; the original was put back, nothing changed";
        case SETUP_RESTORE: return L"writing the hosts file failed AND putting the original back failed. Copy the newest "
                                   L"hosts.bak-" REALM_ID L"-* file in C:\\Windows\\System32\\drivers\\etc over hosts by hand";
        case SETUP_CA: return L"the " REALM_LONG_NAME L" certificate could not be added to the computer trusted roots";
        case SETUP_ARGS: return L"internal error: bad setup arguments";
        case SETUP_LOCK: return L"another launcher is changing the hosts file right now; try again in a moment";
        default: return L"setup was not completed (administrator rights declined?)";
    }
}

// Elevated helper arguments are quoted and validated on the other side: an IPv4 literal and our host name only.
static bool valid_setup_args(const wstr& ip, const wstr& host) {
    IN_ADDR probe;
    if (InetPtonW(AF_INET, ip.c_str(), &probe) != 1) return false;
    if (host.size() < 20 || host.size() > 253) return false;
    for (wchar_t c : host)
        if (!((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9') || c == L'.' || c == L'-')) return false;
    wstr suf = L".actual.battle.net";
    return host.size() > suf.size() && host.compare(host.size() - suf.size(), suf.size(), suf) == 0;
}

// Returns the helper exit code, or (DWORD)-1 when it never ran (UAC declined).
static DWORD setup_elevate(const wstr& self, const wstr& ip, const wstr& host) {
    wstr params = L"--setup \"" + ip + L"\" \"" + host + L"\"";
    SHELLEXECUTEINFOW sei = {sizeof(sei)};
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = self.c_str();
    sei.lpParameters = params.c_str();
    sei.nShow = SW_HIDE;
    if (!ShellExecuteExW(&sei) || !sei.hProcess) return (DWORD)-1;
    WaitForSingleObject(sei.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(sei.hProcess, &code);
    CloseHandle(sei.hProcess);
    return code;
}

// ---- the CA in the computer's trusted roots ---------------------------------------------------------------------
// The client validates against the LOCAL MACHINE root store: with the CA only in the user store Windows reported a
// partial chain and "revocation unknown" and the client dropped the connection (1016). Measured 2026-10-10.

static PCCERT_CONTEXT load_ca() {
    BYTE der[4096];
    DWORD len = sizeof(der);
    if (!CryptStringToBinaryA(CA_PEM, 0, CRYPT_STRING_BASE64HEADER, der, &len, nullptr, nullptr)) return nullptr;
    return CertCreateCertificateContext(X509_ASN_ENCODING, der, len);
}

static bool ca_in_machine_store() {
    PCCERT_CONTEXT ca = load_ca();
    if (!ca) return false;
    bool present = false;
    HCERTSTORE root = CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_LOCAL_MACHINE | CERT_STORE_READONLY_FLAG, L"ROOT");
    if (root) {
        PCCERT_CONTEXT found = CertFindCertificateInStore(root, X509_ASN_ENCODING, 0, CERT_FIND_EXISTING, ca, nullptr);
        present = found != nullptr;
        if (found) CertFreeCertificateContext(found);
        CertCloseStore(root, 0);
    }
    CertFreeCertificateContext(ca);
    return present;
}

// Runs elevated: add the CA to the machine root store. No Windows dialog here, the UAC prompt was the consent.
static bool ca_install_machine() {
    PCCERT_CONTEXT ca = load_ca();
    if (!ca) return false;
    bool ok = false;
    HCERTSTORE root = CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0, CERT_SYSTEM_STORE_LOCAL_MACHINE, L"ROOT");
    if (root) {
        ok = CertAddCertificateContextToStore(root, ca, CERT_STORE_ADD_USE_EXISTING, nullptr) != FALSE;
        CertCloseStore(root, 0);
    }
    CertFreeCertificateContext(ca);
    return ok;
}

// ---- process memory: the runtime key store ----------------------------------------------------------------------

struct Region {
    uintptr_t base;
    size_t size;
};

static std::vector<Region> rw_private_regions(HANDLE h) {
    std::vector<Region> out;
    MEMORY_BASIC_INFORMATION mbi;
    uintptr_t addr = 0;
    while (VirtualQueryEx(h, (LPCVOID)addr, &mbi, sizeof(mbi)) == sizeof(mbi)) {
        if (mbi.State == MEM_COMMIT && mbi.Type == MEM_PRIVATE && mbi.Protect == PAGE_READWRITE)
            out.push_back({(uintptr_t)mbi.BaseAddress, mbi.RegionSize});
        uintptr_t next = (uintptr_t)mbi.BaseAddress + mbi.RegionSize;
        if (next <= addr) break;
        addr = next;
    }
    return out;
}

static bool read_mem(HANDLE h, uintptr_t addr, void* buf, size_t n) {
    SIZE_T got = 0;
    return ReadProcessMemory(h, (LPCVOID)addr, buf, n, &got) && got == n;
}

static bool write_mem(HANDLE h, uintptr_t addr, const void* buf, size_t n) {
    SIZE_T put = 0;
    return WriteProcessMemory(h, (LPVOID)addr, buf, n, &put) && put == n;
}

// The store: 12 entries of 40 bytes: uint32 id (1..12), 32 byte key, flag byte, padding. Same checks as the
// proven patch_keystore.py (2026-10-09).
enum StoreState { INVALID, ORIGINAL, PATCHED };

static unsigned char KNOWN[12][32];

static StoreState store_state(HANDLE h, uintptr_t block, int group, const unsigned char* newkey) {
    unsigned char raw[ENTRY * COUNT];
    if (!read_mem(h, block, raw, sizeof(raw))) return INVALID;
    for (size_t e = 0; e < COUNT; ++e) {
        const unsigned char* o = raw + e * ENTRY;
        uint32_t id = o[0] | (o[1] << 8) | (o[2] << 16) | ((uint32_t)o[3] << 24);
        bool known = memcmp(o + 4, KNOWN[e], 32) == 0;
        bool ok = (int)e == group - 1 ? (known || memcmp(o + 4, newkey, 32) == 0) : known;
        if (id != e + 1 || !ok || o[36] != FLAGS[e] || o[38] != 0 || o[39] != 0) return INVALID;
    }
    return memcmp(raw + (group - 1) * ENTRY + 4, newkey, 32) == 0 ? PATCHED : ORIGINAL;
}

// Reads each region in bounded 4 MB chunks with an overlap, through one reused buffer (Codex review 2026-10-10: one
// buffer per region meant allocations as large as the biggest region, and bad_alloc was not handled).
static std::vector<std::pair<uintptr_t, StoreState>> find_stores(HANDLE h, int group, const unsigned char* newkey) {
    static const size_t CHUNK = (size_t)4 << 20, OVERLAP = 64;
    static std::vector<char> buf(CHUNK + OVERLAP);
    std::vector<std::pair<uintptr_t, StoreState>> found;
    for (const Region& r : rw_private_regions(h)) {
        for (size_t off = 0; off < r.size; off += CHUNK) {
            size_t len = r.size - off < CHUNK + OVERLAP ? r.size - off : CHUNK + OVERLAP;
            SIZE_T got = 0;
            if (!ReadProcessMemory(h, (LPCVOID)(r.base + off), buf.data(), len, &got) || got < 36) continue;
            size_t limit = off + CHUNK < r.size ? CHUNK : got;  // a match inside the overlap belongs to the next chunk
            for (size_t i = 0; i + 32 <= got && i < limit; ++i) {
                if (buf[i] != (char)KNOWN[0][0] || memcmp(&buf[i], KNOWN[0], 32) != 0) continue;
                uintptr_t at = r.base + off + i;
                if (at % 4 != 0 || at < r.base + 4) continue;
                StoreState s = store_state(h, at - 4, group, newkey);
                if (s != INVALID) found.push_back({at - 4, s});
            }
        }
    }
    return found;
}

static bool patch_store(HANDLE h, uintptr_t block, int group, const unsigned char* newkey) {
    uintptr_t addr = block + (group - 1) * ENTRY + 4;
    unsigned char cur[32];
    if (!read_mem(h, addr, cur, 32) || memcmp(cur, KNOWN[group - 1], 32) != 0) return false;
    if (!write_mem(h, addr, newkey, 32)) {
        say(L"key store: WriteProcessMemory failed, error %lu", GetLastError());
        return false;
    }
    return store_state(h, block, group, newkey) == PATCHED;
}

static bool parse_hex(const wstr& hex, unsigned char* out, size_t n) {
    if (hex.size() != n * 2) return false;
    for (size_t i = 0; i < n; ++i) {
        unsigned v = 0;
        for (int k = 0; k < 2; ++k) {
            wchar_t c = hex[i * 2 + k];
            v <<= 4;
            if (c >= L'0' && c <= L'9') v |= c - L'0';
            else if (c >= L'a' && c <= L'f') v |= c - L'a' + 10;
            else if (c >= L'A' && c <= L'F') v |= c - L'A' + 10;
            else return false;
        }
        out[i] = (unsigned char)v;
    }
    return true;
}

// ---- own client copy --------------------------------------------------------------------------------------------
// Operator 2026-10-11: the launcher keeps its own client so our realm never shares the client cache with the official
// one (the official realm's WDB holds Blizzard's Russian NPC names and quest lines we harvest; our answers overwrote
// them). Codex dual-solve picked a private client copy over swapping the Cache folder: a launcher crash can then never
// leave the official game on our cache. The copy sits NEXT TO the official product folder, in the same World of
// Warcraft folder:
//   World of Warcraft\_forever_\                the official client (old beta: _classic_beta_), only read
//   World of Warcraft\_forever_<id>_\            byte-identical copy without Cache, WTF, Logs, Errors; own Cache and WTF
// so the copy finds the game data at the same path (..\Data). Measured on 2026-10-11: a copy elsewhere with a junction to
// Data broke the official game, because the data store records the path it was opened through in Data\data\shmem and
// refuses any other path ("Tact instance creation failed. Error (16): container locked"); with the sibling copy the
// recorded path stays the official one, the official client starts after a copy session and its cache is unchanged.
// The copy is rebuilt in <copy>.stage when the official build changes; Blizzard files are copied, never modified.
// Deleting is only ever done inside the copy's own folders (<product>_<id>_*) and never follows a reparse point.

// left out of the copy and of the manifests; <id>-client.txt is the copy's own marker, never in the official folder
static const wchar_t* COPY_SKIP[] = {L"Cache", L"WTF", L"Logs", L"Errors", L"Screenshots", L"WowB.exe.presuffix", L"Wow.exe.presuffix",
                                     REALM_ID L"-client.txt"};
static const wchar_t* OWN_SUFFIX = REALM_ID L"_";  // _forever_ -> _forever_<id>_ (_classic_beta_ -> _classic_beta_<id>_)

// "SET key value" with any spaces or tabs: the key lowercased and the value without quotes. False for other lines.
static bool parse_set(const wstr& line, wstr& key, wstr& value) {
    wstr t = trim(line);
    if (t.size() < 4 || lower(t.substr(0, 3)) != L"set" || (t[3] != L' ' && t[3] != L'\t')) return false;
    t = trim(t.substr(3));
    size_t sp = t.find_first_of(L" \t");
    key = lower(sp == wstr::npos ? t : t.substr(0, sp));
    value = sp == wstr::npos ? L"" : trim(t.substr(sp));
    if (value.size() >= 2 && value.front() == L'"' && value.back() == L'"') value = value.substr(1, value.size() - 2);
    return !key.empty();
}

// A locale name such as ruRU or enUS: two ASCII lowercase letters, two ASCII uppercase letters.
static bool is_locale(const wstr& c) {
    return c.size() == 4 && c[0] >= L'a' && c[0] <= L'z' && c[1] >= L'a' && c[1] <= L'z' && c[2] >= L'A' && c[2] <= L'Z' &&
           c[3] >= L'A' && c[3] <= L'Z';
}

// The host the game announced in its last "logon requested host=..." line of Connection.log after <from> (an offset into
// the file, updated). Empty when there is no new such line.
static wstr logon_host(const wstr& logpath, size_t& from) {
    std::string raw;
    if (!read_file(logpath, raw)) return L"";
    if (raw.size() < from) from = 0;  // the game started a new log
    wstr host;
    const std::string mark = "logon requested host=\"";
    for (size_t p = raw.find(mark, from); p != std::string::npos; p = raw.find(mark, p + 1)) {
        size_t a = p + mark.size(), b = raw.find('"', a);
        if (b == std::string::npos) break;  // line still being written
        host = to_wide(raw.substr(a, b - a));
        from = b;
    }
    return host;
}

// Locale for a settings file that has none: launcher.ini "locale" wins (caller), else the text locale Battle.net recorded
// in the root .build.info tags ("... ruRU text?") on the row of THIS client's product (the last field of the row equals
// the flavor in <product>\.flavor.info, e.g. wowf; the retail row lists enUS first and must not be used), else enUS.
static wstr default_locale(const wstr& root, const wstr& product) {
    std::string raw;
    wstr flavor;
    if (read_file(product + L"\\.flavor.info", raw))
        for (const wstr& l : lines_of(to_wide(raw))) {
            wstr t = trim(l);
            if (!t.empty()) flavor = t;  // the last non-empty line: "Product Flavor!STRING:0" then the flavor
        }
    if (flavor.empty() || !read_file(root + L"\\.build.info", raw)) return L"enUS";
    for (const wstr& row : lines_of(to_wide(raw))) {
        size_t bar = row.rfind(L'|');
        if (bar == wstr::npos || trim(row.substr(bar + 1)) != flavor) continue;
        for (size_t p = row.find(L" text?"); p != wstr::npos; p = row.find(L" text?", p + 1)) {
            if (p < 4) continue;
            wstr c = row.substr(p - 4, 4);
            if (is_locale(c)) return c;
        }
    }
    return L"enUS";
}

// File name of a path, and the loader DLL that sits next to a client exe: Wow.exe -> Wow_loader.dll (the file is
// wow_loader.dll; NTFS compares names without case), WowB.exe -> WowB_loader.dll.
static wstr base_name(const wstr& p) {
    size_t i = p.find_last_of(L"\\/");
    return i == wstr::npos ? p : p.substr(i + 1);
}
static wstr loader_of(const wstr& exe_name) {
    size_t d = exe_name.rfind(L'.');
    return (d == wstr::npos ? exe_name : exe_name.substr(0, d)) + L"_loader.dll";
}
static const int WDB_KEEP = 30;

static bool is_dir(const wstr& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && (a & FILE_ATTRIBUTE_DIRECTORY);
}

// Lists a folder without . and ..; false on any error other than the normal end of the listing (a folder that cannot be
// read must never look empty).
static bool list_dir(const wstr& dir, std::vector<WIN32_FIND_DATAW>& out) {
    out.clear();
    WIN32_FIND_DATAW fd;
    HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE) return false;
    do {
        if (wcscmp(fd.cFileName, L".") && wcscmp(fd.cFileName, L"..")) out.push_back(fd);
    } while (FindNextFileW(h, &fd));
    DWORD e = GetLastError();
    FindClose(h);
    return e == ERROR_NO_MORE_FILES;
}

// Files the client itself rewrites at run time in both folders (measured 2026-10-11: Fonts\*.slug, *.slugo): copied, but
// left out of the manifest comparison, or every session would force a rebuild. D3D12\ is NOT one of them: it holds the
// Agility SDK DLLs (D3D12Core.dll), which must match (Codex round 5).
static bool runtime_file(const wstr& rel_lower) {
    size_t dot = rel_lower.find_last_of(L'.');
    wstr ext = dot == wstr::npos ? L"" : rel_lower.substr(dot);
    return rel_lower.compare(0, 6, L"fonts\\") == 0 && (ext == L".slug" || ext == L".slugo");
}

static bool skipped_top(const wchar_t* name) {
    for (const wchar_t* s : COPY_SKIP)
        if (!_wcsicmp(name, s)) return true;
    return false;
}

// The canonical long path of an existing folder (links, SUBST and 8.3 names resolved), without the \\?\ prefix; empty
// on failure or for a network path.
static wstr final_path(const wstr& p) {
    HANDLE h = CreateFileW(p.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE) return L"";
    wchar_t buf[2048];
    DWORD n = GetFinalPathNameByHandleW(h, buf, 2048, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    CloseHandle(h);
    if (!n || n >= 2048) return L"";
    wstr s = buf;
    if (s.compare(0, 8, L"\\\\?\\UNC\\") == 0) return L"";
    if (s.compare(0, 4, L"\\\\?\\") == 0) s = s.substr(4);
    return s;
}

static bool has_dotdot(const wstr& p) {
    wstr s = L"\\" + p + L"\\";
    for (wchar_t& c : s) if (c == L'/') c = L'\\';
    return s.find(L"\\..\\") != wstr::npos;
}

// Recursive delete of one of the copy's own folders: `path` must be exactly <product><id>_, .stage or .old. A
// reparse point is removed as a link and never entered.
static bool delete_tree_in(const wstr& path, const wstr& base);
static bool delete_own(const wstr& path, const wstr& own) {
    wstr p = lower(path), o = lower(own);
    if (has_dotdot(path) || (p != o && p != o + L".stage" && p != o + L".old")) {
        say(L"refused to delete %s: not one of the launcher's copy folders", path.c_str());
        return false;
    }
    return delete_tree_in(path, path);
}

// Recursive delete of `path`, which must be `base` itself or lie inside it (used for the copy folders and for the
// launcher's own OfficialWDB archive). Reparse points are removed as links, never entered.
static bool delete_tree_in(const wstr& path, const wstr& base) {
    wstr p = lower(path), b = lower(base);
    if (b.size() < 4 || has_dotdot(path) || (p != b && p.compare(0, b.size() + 1, b + L"\\") != 0)) {
        say(L"refused to delete %s: outside %s", path.c_str(), base.c_str());
        return false;
    }
    DWORD a = GetFileAttributesW(path.c_str());
    if (a == INVALID_FILE_ATTRIBUTES) return GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND;
    if (a & FILE_ATTRIBUTE_REPARSE_POINT) return RemoveDirectoryW(path.c_str()) || DeleteFileW(path.c_str());
    if (!(a & FILE_ATTRIBUTE_DIRECTORY)) {
        SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL);
        return DeleteFileW(path.c_str()) != FALSE;
    }
    std::vector<WIN32_FIND_DATAW> items;
    bool ok = list_dir(path, items);
    for (const auto& fd : items) ok = delete_tree_in(path + L"\\" + fd.cFileName, base) && ok;
    return RemoveDirectoryW(path.c_str()) && ok;
}

// Manifest of a client folder: sorted "relative path|size|write time" lines, top-level COPY_SKIP names left out.
// CopyFileW keeps the write time, so a correct copy has the same manifest as its source. False on any listing error.
static bool manifest(const wstr& dir, const wstr& rel, bool top, std::vector<wstr>& out) {
    std::vector<WIN32_FIND_DATAW> items;
    if (!list_dir(dir, items)) return false;
    for (const auto& fd : items) {
        if (top && skipped_top(fd.cFileName)) continue;
        wstr r = rel.empty() ? wstr(fd.cFileName) : rel + L"\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) return false;  // a link in the client folder: refuse
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (runtime_file(lower(r) + L"\\")) continue;
            out.push_back(lower(r) + L"\\");
            if (!manifest(dir + L"\\" + fd.cFileName, r, false, out)) return false;
        } else if (runtime_file(lower(r))) {
            continue;
        } else {
            wchar_t part[96];
            _snwprintf_s(part, 96, _TRUNCATE, L"|%llu|%lu-%lu", ((unsigned long long)fd.nFileSizeHigh << 32) | fd.nFileSizeLow,
                         fd.ftLastWriteTime.dwHighDateTime, fd.ftLastWriteTime.dwLowDateTime);
            out.push_back(lower(r) + part);
        }
    }
    if (top) std::sort(out.begin(), out.end());
    return true;
}

// Copies a folder tree (top-level COPY_SKIP names left out). Any listing or copy error fails the whole copy.
static bool copy_tree(const wstr& src, const wstr& dst, bool top, uint64_t& bytes) {
    if (!CreateDirectoryW(dst.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
    std::vector<WIN32_FIND_DATAW> items;
    if (!list_dir(src, items)) {
        say(L"own client: cannot list %s (error %lu)", src.c_str(), GetLastError());
        return false;
    }
    for (const auto& fd : items) {
        if (top && skipped_top(fd.cFileName)) continue;
        wstr s = src + L"\\" + fd.cFileName, d = dst + L"\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) {
            say(L"own client: %s is a link, not copied", s.c_str());
            return false;
        }
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!copy_tree(s, d, false, bytes)) return false;
        } else {
            if (!CopyFileW(s.c_str(), d.c_str(), FALSE)) {
                say(L"own client: cannot copy %s (error %lu)", s.c_str(), GetLastError());
                return false;
            }
            bytes += ((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        }
    }
    return true;
}

static bool same_bytes(const wstr& a, const wstr& b) {
    std::string x, y;
    return read_file(a, x) && read_file(b, y) && x == y;
}

// FNV-1a: a short fingerprint of a manifest or a WDB set.
static uint64_t fnv(uint64_t h, const void* p, size_t n) {
    for (size_t i = 0; i < n; ++i) h = (h ^ ((const unsigned char*)p)[i]) * 1099511628211ULL;
    return h;
}

// Identity of the official build: the bytes of .build.info plus the full manifest of the product folder. Empty on error.
static wstr build_key(const wstr& root, const wstr& product, std::vector<wstr>* mf = nullptr) {
    std::string bi;
    std::vector<wstr> m;
    if (!read_file(root + L"\\.build.info", bi) || !manifest(product, L"", true, m) || m.empty()) return L"";
    uint64_t h = fnv(1469598103934665603ULL, bi.data(), bi.size());
    for (const wstr& l : m) h = fnv(h, l.data(), (l.size() + 1) * sizeof(wchar_t));
    if (mf) *mf = m;
    wchar_t hex[40];
    _snwprintf_s(hex, 40, _TRUNCATE, L"v2-%016llx-%zu", (unsigned long long)h, m.size());
    return hex;
}

// Any Wow.exe or WowB.exe running (official, retail or ours; they all share Data): the launcher then changes nothing.
// Fails closed: if the process list cannot be read, it reports "running".
static bool client_running() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return true;
    PROCESSENTRY32W pe = {sizeof(pe)};
    BOOL ok = Process32FirstW(snap, &pe);
    if (!ok) {
        CloseHandle(snap);
        return true;
    }
    bool found = false;
    for (; ok && !found; ok = Process32NextW(snap, &pe)) found = !_wcsicmp(pe.szExeFile, L"WowB.exe") || !_wcsicmp(pe.szExeFile, L"Wow.exe");
    bool broken = !found && GetLastError() != ERROR_NO_MORE_FILES;  // the list ended by an error, not by its end
    CloseHandle(snap);
    return found || broken;
}

static bool is_stamp(const wchar_t* n) {  // YYYYMMDDThhmmssZ
    if (wcslen(n) != 16 || n[8] != L'T' || n[15] != L'Z') return false;
    for (int i = 0; i < 15; ++i)
        if (i != 8 && !iswdigit(n[i])) return false;
    return true;
}

// Copies the official Cache\WDB\<locale>\*.wdb to OfficialWDB\<UTC time>\<locale>\ when they changed since the last
// copy, verifies the copies byte for byte, keeps the newest WDB_KEEP sets. Only reads the official folder; any read or
// listing error cancels the whole set (a partial set must never count as an archive).
static void archive_official_wdb(const wstr& official_product) {
    wstr wdb = official_product + L"\\Cache\\WDB", arch = g_logdir + L"\\OfficialWDB";
    if (!is_dir(wdb)) return;
    std::vector<std::pair<wstr, wstr>> files;  // relative path, source
    std::vector<WIN32_FIND_DATAW> locs, items;
    if (!list_dir(wdb, locs)) { say(L"official cache archive: cannot list %s, skipped", wdb.c_str()); return; }
    for (const auto& loc : locs) {
        if (!(loc.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (loc.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        if (!list_dir(wdb + L"\\" + loc.cFileName, items)) { say(L"official cache archive: cannot list %s, skipped", loc.cFileName); return; }
        for (const auto& f : items) {
            wstr name = f.cFileName;
            if (name.size() < 4 || lower(name.substr(name.size() - 4)) != L".wdb") continue;
            wstr rel = wstr(loc.cFileName) + L"\\" + name;
            files.push_back({rel, wdb + L"\\" + rel});
        }
    }
    if (files.empty()) return;
    std::sort(files.begin(), files.end());
    uint64_t h = 1469598103934665603ULL;
    for (const auto& f : files) {
        std::string raw;
        if (!read_file(f.second, raw)) { say(L"official cache archive: cannot read %s, skipped", f.first.c_str()); return; }
        uint64_t n = raw.size();
        h = fnv(fnv(fnv(h, f.first.data(), (f.first.size() + 1) * sizeof(wchar_t)), &n, sizeof(n)), raw.data(), raw.size());
    }
    wchar_t hex[17];
    _snwprintf_s(hex, 17, _TRUNCATE, L"%016llx", (unsigned long long)h);
    CreateDirectoryW(arch.c_str(), nullptr);
    // sets in creation order (folder creation time), not name order: a clock set back must not make a new set look old
    std::vector<WIN32_FIND_DATAW> dirs;
    std::vector<std::pair<uint64_t, wstr>> byage;
    if (!list_dir(arch, dirs)) return;
    for (const auto& d : dirs)
        if ((d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && is_stamp(d.cFileName) && exists(arch + L"\\" + d.cFileName + L"\\set.hash"))
            byage.push_back({((uint64_t)d.ftCreationTime.dwHighDateTime << 32) | d.ftCreationTime.dwLowDateTime, d.cFileName});
    std::sort(byage.begin(), byage.end());
    std::vector<wstr> sets;
    for (const auto& s : byage) sets.push_back(s.second);
    if (!sets.empty()) {
        std::string last;
        if (read_file(arch + L"\\" + sets.back() + L"\\set.hash", last) && to_wide(last) == hex) return;  // unchanged
    }
    // the first free second from now (a set made in the same second, or a clock set back, must not block a changed set)
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    wchar_t stamp[32] = L"";
    wstr part, done;
    for (int i = 0; i < 60; ++i, u.QuadPart += 10000000ULL) {
        FILETIME f2 = {u.LowPart, u.HighPart};
        SYSTEMTIME t;
        FileTimeToSystemTime(&f2, &t);
        _snwprintf_s(stamp, 32, _TRUNCATE, L"%04d%02d%02dT%02d%02d%02dZ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
        done = arch + L"\\" + stamp;
        part = done + L".partial";
        if (!exists(done)) break;
    }
    if (exists(done)) return;
    delete_tree_in(part, arch);
    if (!CreateDirectoryW(part.c_str(), nullptr)) return;
    for (const auto& f : files) {
        wstr d = part + L"\\" + f.first;
        CreateDirectoryW(dirname(d).c_str(), nullptr);
        if (!CopyFileW(f.second.c_str(), d.c_str(), FALSE) || !same_bytes(f.second, d)) {
            say(L"official cache archive: copy of %s failed, archive skipped", f.first.c_str());
            delete_tree_in(part, arch);
            return;
        }
    }
    if (!write_file(part + L"\\set.hash", to_utf8(hex)) || !MoveFileW(part.c_str(), done.c_str())) {
        delete_tree_in(part, arch);
        return;
    }
    say(L"official cache archived: %zu WDB files -> OfficialWDB\\%s", files.size(), stamp);
    sets.push_back(stamp);  // the newest by creation, whatever its name says
    for (size_t i = 0; i + WDB_KEEP < sets.size(); ++i)
        if (!delete_tree_in(arch + L"\\" + sets[i], arch)) say(L"official cache archive: could not remove old set %s", sets[i].c_str());
}

// Makes sure <product><id>_ (next to the official product folder) is a current, complete copy of the official
// client; returns its path, or empty and a reason. The previous copy is kept as <copy>.old until a session with the new
// copy has succeeded (wWinMain removes it then).
static wstr prepare_own_client(const wstr& root, const wstr& product, const wstr& exe_name, wstr& why) {
    wstr own = product + OWN_SUFFIX, stage = own + L".stage", old = own + L".old";
    std::vector<wstr> mf;
    wstr key = build_key(root, product, &mf);
    if (key.empty()) { why = L"cannot read the official client files"; return L""; }
    if (exists(stage) && !delete_own(stage, own)) { why = L"cannot remove an unfinished copy " + stage; return L""; }
    std::string have;
    if (read_file(own + L"\\" REALM_ID L"-client.txt", have) && to_wide(have) == key) {
        std::vector<wstr> cur;  // the existing copy must still match the official files one for one
        if (manifest(own, L"", true, cur) && cur == mf) return own;
        say(L"own client: the copy no longer matches the official files, rebuilding");
    }
    uint64_t need = 200ULL << 20;
    for (const wstr& l : mf) {
        size_t a = l.find(L'|'), b = a == wstr::npos ? a : l.find(L'|', a + 1);
        if (b != wstr::npos) need += _wcstoui64(l.substr(a + 1, b - a - 1).c_str(), nullptr, 10);
    }
    ULARGE_INTEGER freeb;
    if (!GetDiskFreeSpaceExW(root.c_str(), &freeb, nullptr, nullptr) || freeb.QuadPart < need) {
        why = L"not enough free disk space for the launcher's copy of the client (" + std::to_wstring(need >> 20) + L" MB needed)";
        return L"";
    }
    say(L"own client: building %s (about %llu MB, the game data stays shared)", own.c_str(), (unsigned long long)(need >> 20));
    if (!CreateDirectoryW(stage.c_str(), nullptr)) {
        why = L"cannot create " + stage + L" (Windows error " + std::to_wstring(GetLastError()) + L")";
        return L"";
    }
    uint64_t bytes = 0;
    std::vector<wstr> copied;
    bool ok = copy_tree(product, stage, true, bytes) && manifest(stage, L"", true, copied) && copied == mf &&
              same_bytes(product + L"\\" + exe_name, stage + L"\\" + exe_name) &&
              same_bytes(product + L"\\" + loader_of(exe_name), stage + L"\\" + loader_of(exe_name)) &&
              build_key(root, product) == key;  // an update running during the copy changes the key
    // settings survive a rebuild: our WTF from the previous copy, or the official Config.wtf the first time
    wstr wtf = stage + L"\\WTF";
    uint64_t unused = 0;
    if (ok) ok = CreateDirectoryW(wtf.c_str(), nullptr) != FALSE;
    if (ok && is_dir(own + L"\\WTF")) ok = copy_tree(own + L"\\WTF", wtf, false, unused);
    else if (ok && exists(product + L"\\WTF\\Config.wtf"))
        ok = CopyFileW((product + L"\\WTF\\Config.wtf").c_str(), (wtf + L"\\Config.wtf").c_str(), FALSE) != FALSE;
    if (ok) ok = write_file(stage + L"\\" REALM_ID L"-client.txt", to_utf8(key));
    if (!ok) {
        delete_own(stage, own);
        why = L"copying the client failed or the copy is incomplete (is Battle.net updating the game?)";
        return L"";
    }
    if (is_dir(own)) {
        if (exists(old) && !delete_own(old, own)) { delete_own(stage, own); why = L"cannot remove " + old; return L""; }
        if (!MoveFileW(own.c_str(), old.c_str())) { delete_own(stage, own); why = L"the current copy is in use"; return L""; }
    }
    if (!MoveFileW(stage.c_str(), own.c_str())) {
        DWORD e = GetLastError();
        if (is_dir(old) && !MoveFileW(old.c_str(), own.c_str())) {
            why = L"CRITICAL: the new copy could not be put in place and the previous one could not be restored; it is in " + old;
            return L"";
        }
        delete_own(stage, own);
        why = L"cannot put the new copy in place (Windows error " + std::to_wstring(e) + L")";
        return L"";
    }
    say(L"own client: ready, %llu MB copied, %zu entries verified", (unsigned long long)(bytes >> 20), mf.size());
    return own;
}

#include "updater.h"

// ---- main -------------------------------------------------------------------------------------------------------

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    int argc = __argc;
    wchar_t** argv = __wargv;
    g_logdir = data_dir();
    g_log = _wfopen((g_logdir + L"\\launcher.log").c_str(), L"a, ccs=UTF-8");

    // Elevated helper: validated arguments, hosts first, then the CA; the exit code tells the launcher what happened.
    if (argc >= 2 && wstr(argv[1]) == L"--setup") {
        if (argc != 4 || !valid_setup_args(argv[2], argv[3])) {
            say(L"setup: bad arguments");
            return SETUP_ARGS;
        }
        say(L"setup (elevated): %s %s", argv[2], argv[3]);
        int h = hosts_fix(argv[2], argv[3]);
        if (h != SETUP_OK) {
            say(L"setup: hosts step failed, code %d", h);
            return h;
        }
        if (!ca_in_machine_store() && !ca_install_machine()) {
            say(L"setup: CA step failed, error %lu", GetLastError());
            return SETUP_CA;
        }
        say(L"setup: done");
        return SETUP_OK;
    }

    HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\" REALM_MUTEX_ID L"Launcher");
    if (single && GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr, L"The " REALM_NAME L" launcher is already running.", REALM_NAME L" launcher", MB_OK | MB_ICONINFORMATION);
        return 0;
    }

    wchar_t selfbuf[MAX_PATH];
    GetModuleFileNameW(nullptr, selfbuf, MAX_PATH);
    wstr self = selfbuf;
    say(REALM_ID L"-launcher %s start (%s)", LAUNCHER_VERSION, self.c_str());

    // 0. self-update (docs/update-feed.md). A launcher started by an update confirms its start at once, before even
    // reading its settings (the old one waits at most 30 s, while the game copy below can take minutes and a folder or
    // administrator prompt waits for the player), and removes the previous file once the old one accepted and exited.
    // Otherwise the feed is checked unless launcher.ini says update=0 or <exe>.old is left from an interrupted update.
    // Every failure in the check means "no update". --update-only: do just this part, then exit (unattended tests).
    bool update_only = false;
    DWORD updated_from = 0;
    wstr token;
    for (int k = 1; k < argc; ++k) {
        wstr a = argv[k];
        if (a == L"--update-only") update_only = true;
        else if (a == L"--updated-from" && k + 1 < argc) updated_from = wcstoul(argv[++k], nullptr, 10);
        else if (a == L"--update-token" && k + 1 < argc) token = argv[++k];
    }
    if (updated_from || !token.empty()) {  // both or neither; a half or malformed pair means a broken update start
        if (!updated_from || updated_from == GetCurrentProcessId() || !upd::valid_token(token)) {
            say(L"update: malformed --updated-from/--update-token, ignored");
            updated_from = 0;
        }
    }
    if (updated_from) {
#ifdef LAUNCHER_TEST_EXIT_BEFORE_CONFIRM
        return 7;  // test builds only: a new version that dies before confirming, to prove the rollback
#endif
        upd::confirm_and_clean(self, updated_from, token);
    }
    wstr ini_path = g_logdir + L"\\launcher.ini";
    Ini ini = read_ini(ini_path);
    if (!updated_from) {
        if (exists(self + L".old")) {
            say(L"update: %s.old is left from an interrupted update; it may be the only good copy, so it is kept and no "
                L"update is tried until it is removed or renamed back", self.c_str());
        } else if (!ini.count(L"update") || ini[L"update"] != L"0") {
            std::string bytes, version;
            if (upd::find_update(self + L".bad", bytes, version)) {
                wstr stuck;
                upd::Result r = upd::install(self, bytes, version, single, update_only ? L" --update-only" : L"", stuck);
                if (r == upd::HANDED_OVER || r == upd::OTHER_RUNNING) return 0;
                if (r == upd::STUCK) return update_only ? 3 : fail(stuck.c_str());
            }
        }
    }
    if (update_only) {
        say(L"update-only: done");
        return 0;
    }

    // 1. settings, in %LOCALAPPDATA%\<realm long name> (the exe may sit in a read-only folder)
    const std::pair<const wchar_t*, wstr> defaults[] = {{L"exe", DEF_EXE},       {L"server", DEF_SERVER},
                                                        {L"portal", DEF_PORTAL}, {L"config", DEF_CONFIG},
                                                        {L"key", DEF_KEY},       {L"group", std::to_wstring(DEF_GROUP)}};
    for (const auto& d : defaults)
        if (!ini.count(d.first)) ini[d.first] = d.second;
    wstr client = ini.count(L"client") ? ini[L"client"] : L"";
    // the configured client first, then the known layouts (release _forever_\Wow.exe, old beta _classic_beta_\WowB.exe)
    auto find_exe = [&](const wstr& root) -> wstr {
        if (exists(root + L"\\" + ini[L"exe"])) return ini[L"exe"];
        for (const wchar_t* k : KNOWN_EXES)
            if (exists(root + L"\\" + k)) return k;
        return L"";
    };
    if (!client.empty()) {
        wstr found = find_exe(client);
        if (!found.empty() && found != ini[L"exe"]) {
            say(L"client: %s not found in %s, using %s", ini[L"exe"].c_str(), client.c_str(), found.c_str());
            ini[L"exe"] = found;
        }
    }
    if (client.empty() || !exists(client + L"\\" + ini[L"exe"])) {
        wstr pick = ask_folder();
        if (pick.empty()) return fail(L"no World of Warcraft folder chosen");
        wstr found = find_exe(pick);
        if (found.empty()) {
            say(L"%s\\%s not found", pick.c_str(), ini[L"exe"].c_str());
            return fail(L"that folder does not contain the Forever client");
        }
        ini[L"exe"] = found;
        client = ini[L"client"] = pick;
    }
    if (!write_ini(ini_path, ini)) say(L"warning: could not save %s, the folder will be asked again next time", ini_path.c_str());
    wstr exe = client + L"\\" + ini[L"exe"], product = dirname(exe);

    // own client copy (default; own_client=0 in launcher.ini starts the official install as before). Nothing is done
    // while any Wow.exe or WowB.exe runs: the official folder is only read, the copy and archive live in the launcher's folder.
    bool own_client = !ini.count(L"own_client") || ini[L"own_client"] != L"0";
    wstr own_old;
    if (own_client) {
        // The data store remembers the path it was opened through (Data\data\shmem); the copy must reach Data by the
        // same canonical path Battle.net uses, so an install reached through a link, SUBST, an 8.3 or a network name is
        // refused rather than guessed.
        wchar_t full[MAX_PATH];
        DWORD fn = GetFullPathNameW(client.c_str(), MAX_PATH, full, nullptr);
        if (!fn || fn >= MAX_PATH) return fail(L"The World of Warcraft folder path is too long for the launcher's own game copy.");
        wstr given = full;
        while (given.size() > 3 && (given.back() == L'\\' || given.back() == L'/')) given.pop_back();
        wstr canon = final_path(client);
        if (canon.empty() || lower(canon) != lower(given))
            return fail((L"The World of Warcraft folder " + client + L" is reached through a link, SUBST drive, short or network "
                         L"name (it resolves to " + (canon.empty() ? wstr(L"?") : canon) + L"). The launcher's own game copy needs "
                         L"the real folder: choose it again, or set own_client=0 in launcher.ini to use the shared cache.").c_str());
        if (client_running())
            return fail(L"World of Warcraft is already running. Close the game (also the official one) and start the launcher again.");
        archive_official_wdb(product);
        wstr why, own_product = prepare_own_client(client, product, base_name(exe), why);
        if (own_product.empty())
            return fail((L"Cannot prepare the launcher's own copy of the game: " + why +
                         L"\n\nThe official game folder was not changed.").c_str());
        own_old = own_product + L".old";
        exe = own_product + exe.substr(product.size());
        product = own_product;
        say(L"own client: %s", exe.c_str());
    } else {
        say(L"own_client=0: starting the official client folder (it shares the cache with the official realm)");
    }
    wstr portal = ini[L"portal"];
    wstr host = portal.substr(0, portal.find(L':')) + SUFFIX;  // the client appends the suffix to the host part
    wstr server_ip = resolve_ipv4(ini[L"server"]);
    if (server_ip.empty()) return fail((L"cannot resolve the server address " + ini[L"server"]).c_str());
    int group = _wtoi(ini[L"group"].c_str());
    unsigned char newkey[32];
    if (group < 1 || group > 12 || !parse_hex(ini[L"key"], newkey, 32)) return fail(L"launcher.ini: key must be 64 hex chars, group 1..12");
    for (int i = 0; i < 12; ++i) parse_hex(to_wide(KNOWN_HEX[i]), KNOWN[i], 32);
    say(L"client %s", exe.c_str());
    say(L"realm %s -> %s (%s)", host.c_str(), server_ip.c_str(), ini[L"server"].c_str());

    // 2-3. hosts line and the CA in the computer's trusted roots: one administrator prompt, only when needed
    bool hosts_good = hosts_ok(server_ip, host), ca_good = ca_in_machine_store();
    if (hosts_good && ca_good) {
        say(L"setup: %s points at %s, " REALM_LONG_NAME L" CA trusted", host.c_str(), server_ip.c_str());
    } else {
        say(L"setup: asking for administrator rights once (hosts line%s)", ca_good ? L"" : L" and the " REALM_LONG_NAME L" CA");
        DWORD code = setup_elevate(self, server_ip, host);
        if (code != SETUP_OK) return fail(setup_message(code));
        if (!hosts_ok(server_ip, host) || !ca_in_machine_store()) return fail(L"setup reported success but the check after it failed");
        say(L"setup: done");
    }

    // 4. our own settings file: a copy of Config.wtf with our portal; Config.wtf itself stays as Blizzard left it
    wstr wtf = product + L"\\WTF";
    CreateDirectoryW(wtf.c_str(), nullptr);
    std::string raw;
    wstr cfg = wtf + L"\\Config.wtf";
    if (exists(cfg) && !read_file(cfg, raw)) return fail(L"Config.wtf exists but cannot be read; close the game and try again", GetLastError());
    if (raw.empty()) say(L"settings: no Config.wtf yet, the client starts with its defaults");
    // Exactly one portal, textLocale and audioLocale line in the end (any spacing in the source, last value wins for the
    // locales). A config without a locale makes the release client open its region picker and reset the portal.
    wstr text, have_text, have_audio;
    for (const wstr& line : lines_of(to_wide(raw))) {
        wstr k, v;
        if (parse_set(line, k, v) && (k == L"portal" || k == L"textlocale" || k == L"audiolocale")) {
            if (k == L"textlocale") have_text = v;
            if (k == L"audiolocale") have_audio = v;
            continue;
        }
        text += line + L"\r\n";
    }
    wstr loc = ini.count(L"locale") && !ini[L"locale"].empty() ? ini[L"locale"] : default_locale(client, product);
    if (have_text.empty()) have_text = loc;
    if (have_audio.empty()) have_audio = loc;
    text += L"SET portal \"" + ini[L"portal"] + L"\"\r\n";
    text += L"SET textLocale \"" + have_text + L"\"\r\n";
    text += L"SET audioLocale \"" + have_audio + L"\"\r\n";
    if (!write_atomic(wtf + L"\\" + ini[L"config"], to_utf8(text), false)) return fail(L"cannot write the settings file");
    say(L"settings: WTF\\%s, SET portal \"%s\", textLocale %s, audioLocale %s", ini[L"config"].c_str(), ini[L"portal"].c_str(),
        have_text.c_str(), have_audio.c_str());

    // 5. start the client with our settings file. The previous Connection.log goes first (it is in our own copy and no
    // client runs now): the guard below reads the new log from its start and must not see an old session's host.
    DeleteFileW((product + L"\\Logs\\Connection.log").c_str());
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    wstr cmdline = L"\"" + exe + L"\" -config " + ini[L"config"];
    std::vector<wchar_t> cmd(cmdline.begin(), cmdline.end());
    cmd.push_back(L'\0');
    if (!CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, product.c_str(), &si, &pi))
        return fail(L"cannot start the client", GetLastError());
    CloseHandle(pi.hThread);
    say(L"client started, pid %lu; the launcher keeps the server key in place until the game closes", pi.dwProcessId);

    // 6. key store: appears at Login; scan every 0.5 s until the key is set, then every 3 s for re-created stores
    ULONGLONG t0 = GetTickCount64(), next_scan = 0;
    int patched = 0;
    bool patch_failed = false;
    // Guard: the client must log in at OUR portal host. If its log says it is logging in anywhere else (for instance the
    // release client's region picker reset the portal to EU), the client is closed at once, before the password is sent.
    const wstr guard_log = product + L"\\Logs\\Connection.log", expect_host = lower(host);
    size_t guard_from = 0;
    while (WaitForSingleObject(pi.hProcess, 200) == WAIT_TIMEOUT) {
        wstr seen = logon_host(guard_log, guard_from);
        if (!seen.empty() && lower(seen) != expect_host) {
            TerminateProcess(pi.hProcess, 3);
            CloseHandle(pi.hProcess);
            say(L"GUARD: the game began a login at %s, not %s; it was closed", seen.c_str(), expect_host.c_str());
            return fail((L"The game tried to log in at " + seen + L" instead of the " REALM_NAME L" realm (" + expect_host +
                         L"), so the launcher closed it before your password was sent.\n\nStart the launcher again. If this repeats, "
                         L"send launcher.log.").c_str());
        }
        if (GetTickCount64() < next_scan) continue;
        next_scan = GetTickCount64() + (patched ? 3000 : 500);
        try {
            for (const auto& st : find_stores(pi.hProcess, group, newkey)) {
                if (st.second != ORIGINAL) continue;
                if (patch_store(pi.hProcess, st.first, group, newkey)) {
                    ++patched;
                    say(L"server key set (store at 0x%llX, %.1f s after start)", (unsigned long long)st.first, (GetTickCount64() - t0) / 1000.0);
                } else {
                    patch_failed = true;
                }
            }
        } catch (...) {
            say(L"key store: scan error, retrying");
        }
    }
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    say(L"client exited with code %lu; server key set %d time(s)", code, patched);
    if (own_client && patched && exists(own_old)) {  // the new copy has run a real session: the previous one can go
        wstr own = own_old.substr(0, own_old.size() - 4);
        if (delete_own(own_old, own)) say(L"own client: previous copy removed");
    }
    if (patch_failed && !patched)
        return fail(L"The game found its key store but the launcher could not set the " REALM_NAME L" server key in it, so the "
                    L"login to " REALM_NAME L" could not succeed. Run the launcher again; if it repeats, send launcher.log.");
    return 0;
}
