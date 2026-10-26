// Self-update for platform windows-x64, as docs/update-feed.md (schema 1) specifies. Included by forever-launcher.cpp
// after its helpers (say, read_file, write_file, exists, wstr, to_wide, to_ascii). Native APIs only: WinHTTP (system
// proxy honoured), CNG for SHA-256 and ECDSA P-256. Every failure before the swap means "no update": the launcher
// carries on and starts the game as before.
#pragma once
#include <winhttp.h>
#include <bcrypt.h>
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")

#ifndef LAUNCHER_VERSION
#define LAUNCHER_VERSION L"1.1.0"
#endif

namespace upd {

static const size_t MAX_MANIFEST = 64 * 1024, MAX_SIG = 1024, MAX_ASSET = 50 * 1024 * 1024;
static const DWORD HANDSHAKE_MS = 30000;

// ---- strict minimal JSON (RFC 8259 syntax): objects, strings and non-negative integers are kept; arrays, other
// numbers and literals are checked and kept as OTHER. Duplicate keys, invalid UTF-8 or any syntax error makes the
// whole document invalid.
struct J {
    enum Type { OBJ, STR, INT, OTHER } t = OTHER;
    std::map<std::string, J> obj;
    std::string s;
    long long i = 0;
};

struct Parser {
    const std::string& in;
    size_t p = 0;
    int depth = 0;
    explicit Parser(const std::string& s) : in(s) {}
    bool more() const { return p < in.size(); }
    void ws() { while (more() && (in[p] == ' ' || in[p] == '\t' || in[p] == '\n' || in[p] == '\r')) ++p; }
    bool digits() {
        size_t b = p;
        while (more() && in[p] >= '0' && in[p] <= '9') ++p;
        return p > b;
    }
    bool lit(const char* w) {
        size_t n = strlen(w);
        if (in.compare(p, n, w) != 0) return false;
        p += n;
        return true;
    }
    bool hex4(unsigned& u) {
        if (p + 4 > in.size()) return false;
        u = 0;
        for (int k = 0; k < 4; ++k) {
            char c = in[p++];
            int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) return false;
            u = u * 16 + d;
        }
        return true;
    }
    static void utf8(std::string& out, unsigned cp) {
        if (cp < 0x80) out += (char)cp;
        else if (cp < 0x800) { out += (char)(0xC0 | (cp >> 6)); out += (char)(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { out += (char)(0xE0 | (cp >> 12)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
        else { out += (char)(0xF0 | (cp >> 18)); out += (char)(0x80 | ((cp >> 12) & 0x3F)); out += (char)(0x80 | ((cp >> 6) & 0x3F)); out += (char)(0x80 | (cp & 0x3F)); }
    }
    bool str(std::string& out) {
        if (!more() || in[p] != '"') return false;
        ++p;
        while (more()) {
            unsigned char c = (unsigned char)in[p++];
            if (c == '"') return true;
            if (c < 0x20) return false;
            if (c != '\\') { out += (char)c; continue; }
            if (!more()) return false;
            char e = in[p++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    unsigned u;
                    if (!hex4(u)) return false;
                    if (u >= 0xDC00 && u <= 0xDFFF) return false;  // a lone low surrogate
                    if (u >= 0xD800 && u <= 0xDBFF) {
                        unsigned lo;
                        if (!lit("\\u") || !hex4(lo) || lo < 0xDC00 || lo > 0xDFFF) return false;
                        u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    utf8(out, u);
                    break;
                }
                default: return false;
            }
        }
        return false;
    }
    bool number(J& v) {  // -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        size_t b = p;
        bool neg = false, frac = false, exp = false;
        if (in[p] == '-') { neg = true; ++p; }
        if (!more()) return false;
        if (in[p] == '0') ++p;
        else if (in[p] >= '1' && in[p] <= '9') digits();
        else return false;
        size_t int_end = p;
        if (more() && in[p] == '.') {
            ++p;
            if (!digits()) return false;
            frac = true;
        }
        if (more() && (in[p] == 'e' || in[p] == 'E')) {
            ++p;
            if (more() && (in[p] == '+' || in[p] == '-')) ++p;
            if (!digits()) return false;
            exp = true;
        }
        if (!neg && !frac && !exp && int_end - b <= 15) {
            v.t = J::INT;
            v.i = std::stoll(in.substr(b, int_end - b));
        } else {
            v.t = J::OTHER;
        }
        return true;
    }
    bool value(J& v) {
        if (++depth > 16) return false;
        ws();
        bool ok = false;
        if (!more()) ok = false;
        else if (in[p] == '{') {
            v.t = J::OBJ;
            ++p;
            ws();
            if (more() && in[p] == '}') { ++p; ok = true; }
            else {
                for (;;) {
                    ws();
                    std::string k;
                    if (!str(k)) break;
                    ws();
                    if (!more() || in[p] != ':') break;
                    ++p;
                    J child;
                    if (!value(child)) break;
                    if (!v.obj.emplace(k, std::move(child)).second) break;  // duplicate key
                    ws();
                    if (more() && in[p] == ',') { ++p; continue; }
                    if (more() && in[p] == '}') { ++p; ok = true; }
                    break;
                }
            }
        } else if (in[p] == '[') {
            v.t = J::OTHER;
            ++p;
            ws();
            if (more() && in[p] == ']') { ++p; ok = true; }
            else {
                for (;;) {
                    J child;
                    if (!value(child)) break;
                    ws();
                    if (more() && in[p] == ',') { ++p; continue; }
                    if (more() && in[p] == ']') { ++p; ok = true; }
                    break;
                }
            }
        } else if (in[p] == '"') {
            v.t = J::STR;
            ok = str(v.s);
        } else if (in[p] == '-' || (in[p] >= '0' && in[p] <= '9')) {
            ok = number(v);
        } else {
            v.t = J::OTHER;
            ok = lit("true") || lit("false") || lit("null");
        }
        --depth;
        return ok;
    }
};

static bool parse_json(const std::string& text, J& root) {
    root = J();
    if (text.size() >= 3 && text.compare(0, 3, "\xEF\xBB\xBF") == 0) return false;  // the tool never writes a BOM
    if (!text.empty() && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), (int)text.size(), nullptr, 0))
        return false;  // not valid UTF-8
    Parser ps(text);
    if (!ps.value(root)) return false;
    ps.ws();
    return ps.p == text.size();
}

// ---- versions, hex, URL -----------------------------------------------------------------------------------------
static bool parse_version(const std::string& v, unsigned out[3]) {
    size_t p = 0;
    for (int k = 0; k < 3; ++k) {
        size_t b = p;
        while (p < v.size() && v[p] >= '0' && v[p] <= '9') ++p;
        size_t n = p - b;
        if (n == 0 || n > 5 || (n > 1 && v[b] == '0')) return false;
        out[k] = (unsigned)std::stoul(v.substr(b, n));
        if (out[k] > 65535) return false;
        if (k < 2) {
            if (p >= v.size() || v[p] != '.') return false;
            ++p;
        }
    }
    return p == v.size();
}

static bool newer(const unsigned a[3], const unsigned b[3]) {  // a > b
    for (int k = 0; k < 3; ++k)
        if (a[k] != b[k]) return a[k] > b[k];
    return false;
}

static bool segment_ok(const std::string& s) {
    if (s.empty() || s == "." || s == "..") return false;
    for (char c : s)
        if (!(isalnum((unsigned char)c) || c == '.' || c == '_' || c == '-')) return false;
    return true;
}

static bool url_ok(const std::string& url, const std::string& repo) {
    std::string prefix = "https://github.com/" + repo + "/releases/download/";
    if (url.compare(0, prefix.size(), prefix) != 0) return false;
    std::string tail = url.substr(prefix.size());
    size_t slash = tail.find('/');
    return slash != std::string::npos && tail.find('/', slash + 1) == std::string::npos &&
           segment_ok(tail.substr(0, slash)) && segment_ok(tail.substr(slash + 1));
}

static bool from_hex(const std::string& h, std::vector<unsigned char>& out) {
    if (h.size() % 2) return false;
    out.clear();
    for (size_t k = 0; k < h.size(); k += 2) {
        int v = 0;
        for (int j = 0; j < 2; ++j) {
            char c = h[k + j];
            int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) return false;
            v = v * 16 + d;
        }
        out.push_back((unsigned char)v);
    }
    return true;
}

static std::string to_hex(const unsigned char* b, size_t n) {
    static const char* d = "0123456789abcdef";
    std::string s;
    for (size_t k = 0; k < n; ++k) {
        s += d[b[k] >> 4];
        s += d[b[k] & 15];
    }
    return s;
}

// ---- CNG ----------------------------------------------------------------------------------------------------------
static bool sha256(const std::string& data, unsigned char out[32]) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0)) return false;
    NTSTATUS st = BCryptHash(alg, nullptr, 0, (PUCHAR)data.data(), (ULONG)data.size(), out, 32);
    BCryptCloseAlgorithmProvider(alg, 0);
    return st == 0;
}

// The spec's "Native verification, Windows": CNG takes the SHA-256 of the manifest and the raw 64-byte r||s.
static bool verify_signature(const std::string& manifest, const std::string& sig_text, const std::string& pubhex) {
    std::vector<unsigned char> pub;
    if (!from_hex(pubhex, pub) || pub.size() != 64) return false;
    std::string b64 = sig_text;
    while (!b64.empty() && strchr(" \t\r\n", b64.back())) b64.pop_back();
    size_t lead = 0;
    while (lead < b64.size() && strchr(" \t\r\n", b64[lead])) ++lead;
    b64 = b64.substr(lead);
    if (b64.size() != 88) return false;  // 64 bytes are exactly 88 base64 characters (ending in "==")
    for (char c : b64)
        if (!(isalnum((unsigned char)c) || c == '+' || c == '/' || c == '=')) return false;
    unsigned char sig[64];
    DWORD siglen = sizeof(sig), skip = 0, flags = 0;
    if (!CryptStringToBinaryA(b64.c_str(), (DWORD)b64.size(), CRYPT_STRING_BASE64, sig, &siglen, &skip, &flags) || siglen != 64)
        return false;
    std::vector<unsigned char> blob(sizeof(BCRYPT_ECCKEY_BLOB) + 64);
    auto* hdr = reinterpret_cast<BCRYPT_ECCKEY_BLOB*>(blob.data());
    hdr->dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
    hdr->cbKey = 32;
    memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), pub.data(), 64);
    unsigned char digest[32];
    if (!sha256(manifest, digest)) return false;
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_KEY_HANDLE key = nullptr;
    bool ok = false;
    if (!BCryptOpenAlgorithmProvider(&alg, BCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0)) {
        if (!BCryptImportKeyPair(alg, nullptr, BCRYPT_ECCPUBLIC_BLOB, &key, blob.data(), (ULONG)blob.size(), 0)) {
            ok = BCryptVerifySignature(key, nullptr, digest, 32, sig, 64, 0) == 0;
            BCryptDestroyKey(key);
        }
        BCryptCloseAlgorithmProvider(alg, 0);
    }
    return ok;
}

// ---- WinHTTP ------------------------------------------------------------------------------------------------------
// The request runs on a worker thread that alone owns its WinHTTP handles; no handle is ever touched by two threads.
// The caller waits at most `total_ms`; when that runs out it stops waiting, reports failure and marks the job
// abandoned. The worker then stops at its next read (each WinHTTP step has its own timeout), closes its handles and
// frees the shared job when it is the last owner. Nothing it does after that reaches the caller.
struct HttpJob {
    wstr url;
    size_t limit = 0;
    DWORD step_ms = 0;
    std::string out;
    bool ok = false;
    volatile LONG abandoned = 0;
    volatile LONG refs = 2;  // the caller and the worker
};

static void release(HttpJob* j) {
    if (InterlockedDecrement(&j->refs) == 0) delete j;
}

static DWORD WINAPI http_worker(LPVOID arg) {
    auto* j = static_cast<HttpJob*>(arg);
    URL_COMPONENTS uc = {sizeof(uc)};
    wchar_t host[256], path[2048];
    uc.lpszHostName = host;
    uc.dwHostNameLength = 256;
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = 2048;
    HINTERNET s = nullptr, c = nullptr, r = nullptr;
    if (WinHttpCrackUrl(j->url.c_str(), 0, 0, &uc) && uc.nScheme == INTERNET_SCHEME_HTTPS)
        s = WinHttpOpen(L"forever-launcher/" LAUNCHER_VERSION, WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                        WINHTTP_NO_PROXY_BYPASS, 0);
    if (s) {
        WinHttpSetTimeouts(s, 5000, 5000, (int)j->step_ms, (int)j->step_ms);
        c = WinHttpConnect(s, host, uc.nPort, 0);
    }
    if (c) r = WinHttpOpenRequest(c, L"GET", path, nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    bool ok = false;
    std::string body;
    if (r && WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && WinHttpReceiveResponse(r, nullptr)) {
        DWORD status = 0, len = sizeof(status);
        if (WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &len,
                                WINHTTP_NO_HEADER_INDEX) &&
            status == 200) {
            ok = true;
            std::vector<char> buf(65536);
            for (;;) {
                if (j->abandoned) { ok = false; break; }
                DWORD got = 0;
                if (!WinHttpReadData(r, buf.data(), (DWORD)buf.size(), &got)) { ok = false; break; }
                if (got == 0) break;
                if (body.size() + got > j->limit) { ok = false; break; }
                body.append(buf.data(), got);
            }
        }
    }
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    if (ok) j->out.swap(body);
    j->ok = ok;
    release(j);
    return 0;
}

// GET over HTTPS (redirects followed; WinHTTP's default policy refuses HTTPS->HTTP). Fails on a non-200 status, on
// more than `limit` bytes, and when `total_ms` runs out, whatever the request is doing then.
static bool http_get(const wstr& url, size_t limit, DWORD total_ms, std::string& out) {
    out.clear();
    auto* j = new HttpJob;
    j->url = url;
    j->limit = limit;
    j->step_ms = std::min<DWORD>(total_ms, 10000);
    HANDLE th = CreateThread(nullptr, 0, http_worker, j, 0, nullptr);
    if (!th) {
        delete j;  // the worker never started: the caller is the only owner
        return false;
    }
    bool finished = WaitForSingleObject(th, total_ms) == WAIT_OBJECT_0;
    CloseHandle(th);
    bool ok = false;
    if (finished) {
        ok = j->ok;  // the thread has exited: its writes are complete and visible
        if (ok) out.swap(j->out);
    } else {
        InterlockedExchange(&j->abandoned, 1);
    }
    release(j);
    return ok;
}

// ---- the check: returns true and fills `bytes` when a verified newer build is ready to install --------------------
// `bad` is <exe>.bad: a build that already failed to start here is not downloaded and tried again.
static bool find_update(const wstr& bad, std::string& bytes, std::string& version_out) {
    std::string repo = to_ascii(REALM_UPDATE_REPO), pubhex = to_ascii(REALM_UPDATE_PUBKEY), realm = to_ascii(REALM_ID);
    if (repo.empty() || pubhex.empty()) return false;
    wstr base = L"https://github.com/" + to_wide(repo) + L"/releases/latest/download/";
    std::string manifest, sig;
    if (!http_get(base + L"manifest.json", MAX_MANIFEST, 10000, manifest) || !http_get(base + L"manifest.json.sig", MAX_SIG, 10000, sig)) {
        say(L"update: no feed reachable (or not published yet)");
        return false;
    }
    if (!verify_signature(manifest, sig, pubhex)) {
        say(L"update: manifest signature does not verify, ignored");
        return false;
    }
    J root;
    if (!parse_json(manifest, root) || root.t != J::OBJ) return say(L"update: manifest is not valid JSON"), false;
    auto get = [](const J& o, const char* k) -> const J* {
        auto it = o.obj.find(k);
        return it == o.obj.end() ? nullptr : &it->second;
    };
    const J *schema = get(root, "schema"), *rlm = get(root, "realm"), *plats = get(root, "platforms");
    if (!schema || schema->t != J::INT || schema->i != 1) return say(L"update: unknown manifest schema"), false;
    if (!rlm || rlm->t != J::STR || rlm->s != realm) return say(L"update: manifest is for another realm"), false;
    if (!plats || plats->t != J::OBJ || plats->obj.empty()) return say(L"update: manifest has no platforms"), false;
    for (const auto& kv : plats->obj)
        if (kv.first != "windows-x64" && kv.first != "macos-universal") return say(L"update: unknown platform in manifest"), false;
    const J* w = get(*plats, "windows-x64");
    if (!w) return say(L"update: no Windows build in the manifest"), false;
    const J *ver = get(*w, "version"), *url = get(*w, "url"), *hash = get(*w, "sha256"), *size = get(*w, "size");
    unsigned have[3], offered[3];
    if (w->t != J::OBJ || !ver || ver->t != J::STR || !parse_version(ver->s, offered) || !url || url->t != J::STR ||
        !url_ok(url->s, repo) || !hash || hash->t != J::STR || hash->s.size() != 64 ||
        hash->s.find_first_not_of("0123456789abcdef") != std::string::npos || !size || size->t != J::INT || size->i <= 0 ||
        size->i > (long long)MAX_ASSET)
        return say(L"update: Windows entry of the manifest is malformed"), false;
    parse_version(to_ascii(LAUNCHER_VERSION), have);
    if (!newer(offered, have)) {
        say(L"update: up to date (%s, feed offers %s)", LAUNCHER_VERSION, to_wide(ver->s).c_str());
        return false;
    }
    std::string failed;
    unsigned char fd[32];
    if (read_file(bad, failed) && sha256(failed, fd) && to_hex(fd, 32) == hash->s) {
        say(L"update: %s failed to start here before (%s); not trying it again", to_wide(ver->s).c_str(), bad.c_str());
        return false;
    }
    say(L"update: %s -> %s, downloading", LAUNCHER_VERSION, to_wide(ver->s).c_str());
    if (!http_get(to_wide(url->s), (size_t)size->i, 120000, bytes) || bytes.size() != (size_t)size->i)
        return say(L"update: download failed or has the wrong size"), false;
    unsigned char d[32];
    if (!sha256(bytes, d) || to_hex(d, 32) != hash->s) return say(L"update: download does not match the signed SHA-256"), false;
    version_out = ver->s;
    return true;
}

// ---- install and handshake ----------------------------------------------------------------------------------------
static wstr random_token() {
    unsigned char b[16];
    if (BCryptGenRandom(nullptr, b, sizeof(b), BCRYPT_USE_SYSTEM_PREFERRED_RNG)) return L"";
    return to_wide(to_hex(b, 16));
}

// Two events per attempt: the new launcher sets "ready"; the old one answers "accepted" only when it has decided to hand
// over. The new launcher deletes <exe>.old only after "accepted", so an old launcher that timed out and is rolling back
// can never lose its file to a late "ready".
static wstr ready_name(const wstr& token) { return L"Local\\" REALM_MUTEX_ID L"LauncherUpdated-" + token; }
static wstr accepted_name(const wstr& token) { return L"Local\\" REALM_MUTEX_ID L"LauncherAccepted-" + token; }

static bool valid_token(const wstr& t) {
    if (t.size() != 32) return false;
    for (wchar_t c : t)
        if (!((c >= L'0' && c <= L'9') || (c >= L'a' && c <= L'f'))) return false;
    return true;
}

static wstr quote(const wstr& a) { return L"\"" + a + L"\""; }  // our own arguments only: no quotes or backslash runs inside

static HANDLE new_event(const wstr& name) {  // a fresh, non-signalled, manual-reset event; nullptr if the name exists
    HANDLE e = CreateEventW(nullptr, TRUE, FALSE, name.c_str());
    if (e && GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(e);
        return nullptr;
    }
    return e;
}

enum Result { NO_UPDATE, HANDED_OVER, ROLLED_BACK, OTHER_RUNNING, STUCK };

// Steps 1-5 of "Installing an update" on Windows. `single` is the single-instance mutex: released just before the new
// launcher starts, taken back before any file is touched in a rollback. `extra` are arguments passed to the new one.
// HANDED_OVER / OTHER_RUNNING: the caller exits quietly. STUCK: the caller shows `stuck_msg` and stops; the files are
// then exactly as the log says, and the previous launcher is never deleted.
static Result install(const wstr& self, const std::string& bytes, const std::string& version, HANDLE& single,
                      const wstr& extra, wstr& stuck_msg) {
    wstr fresh = self + L".new", old = self + L".old", bad = self + L".bad";
    auto stuck = [&](const wstr& state) {
        say(L"update: STUCK, %s", state.c_str());
        stuck_msg = L"An update of the launcher could not be completed, and the launcher could not undo it by itself.\n\n" + state +
                    L"\n\nTo fix it by hand: close every launcher, delete " + self + L" if it is there, and rename " + old + L" to " + self + L".";
        return STUCK;
    };
    if (exists(old)) return say(L"update: %s exists; not updating", old.c_str()), NO_UPDATE;  // the caller checks first too
    DeleteFileW(fresh.c_str());
    std::string back;
    unsigned char d1[32], d2[32];
    if (!write_file(fresh, bytes) || !read_file(fresh, back) || !sha256(back, d1) || !sha256(bytes, d2) || memcmp(d1, d2, 32)) {
        DeleteFileW(fresh.c_str());
        say(L"update: could not write %s", fresh.c_str());
        return NO_UPDATE;
    }
    wstr token = random_token();
    HANDLE ready = token.empty() ? nullptr : new_event(ready_name(token));
    HANDLE accepted = ready ? new_event(accepted_name(token)) : nullptr;
    if (!ready || !accepted) {
        if (ready) CloseHandle(ready);
        DeleteFileW(fresh.c_str());
        say(L"update: could not create the handshake events");
        return NO_UPDATE;
    }
    auto close_events = [&] {
        CloseHandle(ready);
        CloseHandle(accepted);
    };
    if (!MoveFileExW(self.c_str(), old.c_str(), MOVEFILE_WRITE_THROUGH)) {
        say(L"update: cannot rename the running launcher (error %lu)", GetLastError());
        close_events();
        DeleteFileW(fresh.c_str());
        return NO_UPDATE;
    }
    if (!MoveFileExW(fresh.c_str(), self.c_str(), MOVEFILE_WRITE_THROUGH)) {
        DWORD e = GetLastError();
        if (!MoveFileExW(old.c_str(), self.c_str(), MOVEFILE_WRITE_THROUGH)) {
            DWORD e2 = GetLastError();
            close_events();
            return stuck(L"Moving the new launcher in failed (error " + std::to_wstring(e) + L") and putting the running one back failed (error " +
                         std::to_wstring(e2) + L"): the new build is " + fresh + L", the previous one is " + old + L".");
        }
        say(L"update: cannot move the new launcher in (error %lu), previous one restored", e);
        close_events();
        DeleteFileW(fresh.c_str());
        return NO_UPDATE;
    }
    if (single) {  // the new launcher must be able to take the single-instance lock
        ReleaseMutex(single);
        CloseHandle(single);
        single = nullptr;
    }
    wstr cmd = quote(self) + L" --updated-from " + std::to_wstring(GetCurrentProcessId()) + L" --update-token " + token + extra;
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi = {};
    std::vector<wchar_t> cmdbuf(cmd.begin(), cmd.end());
    cmdbuf.push_back(0);
    if (CreateProcessW(self.c_str(), cmdbuf.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        HANDLE both[2] = {ready, pi.hProcess};
        DWORD w = WaitForMultipleObjects(2, both, FALSE, HANDSHAKE_MS);
        if (w == WAIT_OBJECT_0) {
            if (SetEvent(accepted)) {  // only now may the new launcher remove the previous file
                say(L"update: %s started and confirmed, handing over", to_wide(version).c_str());
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                close_events();
                return HANDED_OVER;
            }
            say(L"update: the new launcher confirmed, but accepting it failed (error %lu); rolling back", GetLastError());
            w = WAIT_TIMEOUT;  // treated as no confirmation: the new process is stopped below
        } else {
            say(L"update: the new launcher %s within %lu s; rolling back",
                w == WAIT_OBJECT_0 + 1 ? L"exited before confirming" : L"did not confirm", HANDSHAKE_MS / 1000);
        }
#ifdef LAUNCHER_TEST_ROLLBACK_DELAY_MS
        Sleep(LAUNCHER_TEST_ROLLBACK_DELAY_MS);  // test builds only: widen the window between the timeout and the rollback
#endif
        if (w != WAIT_OBJECT_0 + 1) {
            BOOL killed = TerminateProcess(pi.hProcess, 1);
            DWORD kill_err = killed ? 0 : GetLastError();
            DWORD gone = WaitForSingleObject(pi.hProcess, 10000);
            DWORD wait_err = gone == WAIT_FAILED ? GetLastError() : 0;
            if (gone != WAIT_OBJECT_0) {
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                close_events();
                return stuck(L"The new launcher did not confirm its start and could not be stopped (TerminateProcess " +
                             wstr(killed ? L"succeeded" : L"failed, error " + std::to_wstring(kill_err)) + L"; waiting for it " +
                             wstr(gone == WAIT_TIMEOUT ? L"timed out after 10 s" : L"failed, error " + std::to_wstring(wait_err)) +
                             L"): the new build is " + self + L", the previous one is " + old + L".");
            }
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        say(L"update: cannot start the new launcher (error %lu); rolling back", GetLastError());
    }
    close_events();
    // the new process is gone: take the lock back BEFORE touching a file
    single = CreateMutexW(nullptr, TRUE, L"Local\\" REALM_MUTEX_ID L"Launcher");
    DWORD me = GetLastError();
    if (!single)
        return stuck(L"The lock could not be taken back (error " + std::to_wstring(me) + L"): the new build is " + self +
                     L", the previous one is " + old + L".");
    if (me == ERROR_ALREADY_EXISTS) {
        CloseHandle(single);
        single = nullptr;
        say(L"update: another launcher started meanwhile; files left as they are (new build %s, previous %s); this one stops",
            self.c_str(), old.c_str());
        return OTHER_RUNNING;
    }
    if (!DeleteFileW(bad.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND)
        say(L"update: could not delete the earlier %s (error %lu)", bad.c_str(), GetLastError());
    if (!MoveFileExW(self.c_str(), bad.c_str(), MOVEFILE_WRITE_THROUGH)) {
        DWORD e = GetLastError();
        return stuck(L"Moving the failed build aside failed (error " + std::to_wstring(e) + L"): the failed build is " + self +
                     L", the previous one is " + old + L".");
    }
    if (!MoveFileExW(old.c_str(), self.c_str(), MOVEFILE_WRITE_THROUGH)) {
        DWORD e = GetLastError();
        return stuck(L"Putting the previous launcher back failed (error " + std::to_wstring(e) + L"): the failed build is " + bad +
                     L", the previous one is " + old + L".");
    }
    say(L"update: previous launcher restored; the failed build is kept as %s", bad.c_str());
    return ROLLED_BACK;
}

// In the new launcher: confirm the start, and remove <exe>.old only after the old launcher accepted and exited.
static void confirm_and_clean(const wstr& self, DWORD old_pid, const wstr& token) {
    wstr old = self + L".old";
#ifdef LAUNCHER_TEST_CONFIRM_DELAY_MS
    Sleep(LAUNCHER_TEST_CONFIRM_DELAY_MS);  // test builds only: confirm late, after the old launcher's timeout
#endif
    HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, ready_name(token).c_str());
    HANDLE accepted = OpenEventW(SYNCHRONIZE, FALSE, accepted_name(token).c_str());
    if (!ready || !accepted) {
        say(L"update: no handshake from the old launcher; keeping %s", old.c_str());
        if (ready) CloseHandle(ready);
        if (accepted) CloseHandle(accepted);
        return;
    }
    SetEvent(ready);
    CloseHandle(ready);
    say(L"update: running %s, start confirmed", LAUNCHER_VERSION);
    DWORD a = WaitForSingleObject(accepted, HANDSHAKE_MS + 5000);
    CloseHandle(accepted);
    if (a != WAIT_OBJECT_0) {
        say(L"update: the old launcher did not accept the start; keeping %s", old.c_str());
        return;
    }
    HANDLE oldp = OpenProcess(SYNCHRONIZE, FALSE, old_pid);
    DWORD gone = oldp ? WaitForSingleObject(oldp, 15000) : WAIT_OBJECT_0;  // no handle: it has exited already
    if (oldp) CloseHandle(oldp);
    if (gone != WAIT_OBJECT_0) {
        say(L"update: the old launcher is still running; keeping %s for now", old.c_str());
        return;
    }
    for (int k = 0; k < 20 && exists(old) && !DeleteFileW(old.c_str()); ++k) Sleep(250);
    if (exists(old)) say(L"update: could not delete %s yet", old.c_str());
}

}  // namespace upd
