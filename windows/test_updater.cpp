// Tests of the self-update helpers (updater.h): JSON, versions, URLs, the signature on docs/test-vector, and the
// whole-request deadline of http_get. Built and run by test.cmd against profiles/example. The deadline test needs the
// internet (httpbin.org); it reports SKIP when that host cannot be reached at all.
#include "forever-launcher.cpp"
#include <iostream>

static int fails = 0;
static void check(const char* name, bool ok) {
    std::cout << (ok ? "PASS " : "FAIL ") << name << "\n";
    if (!ok) ++fails;
}

static bool json_ok(const std::string& t) {
    upd::J r;
    return upd::parse_json(t, r);
}

int main() {
    // JSON
    check("json: object with string and integer", json_ok("{\"a\":\"b\",\"n\":12}"));
    upd::J r;
    check("json: integer value", upd::parse_json("{\"n\":431104}", r) && r.obj["n"].t == upd::J::INT && r.obj["n"].i == 431104);
    check("json: duplicate key refused", !json_ok("{\"a\":1,\"a\":1}"));
    check("json: lone minus refused", !json_ok("{\"x\":-}"));
    check("json: 1e+ refused", !json_ok("{\"x\":1e+}"));
    check("json: 01 refused", !json_ok("{\"x\":01}"));
    check("json: 1. refused", !json_ok("{\"x\":1.}"));
    check("json: -1.5e+3 accepted as other", upd::parse_json("{\"x\":-1.5e+3}", r) && r.obj["x"].t == upd::J::OTHER);
    check("json: array and literals accepted", json_ok("{\"x\":[1,\"a\",true,null,{\"y\":false}]}"));
    check("json: \\u0061 decodes", upd::parse_json("{\"r\":\"\\u0061lgalon\"}", r) && r.obj["r"].s == "algalon");
    check("json: surrogate pair decodes", upd::parse_json("{\"r\":\"\\ud83d\\ude00\"}", r) && r.obj["r"].s == "\xF0\x9F\x98\x80");
    check("json: lone surrogate refused", !json_ok("{\"r\":\"\\ud83d\"}"));
    check("json: BOM refused", !json_ok("\xEF\xBB\xBF{}"));
    check("json: invalid UTF-8 refused", !json_ok("{\"r\":\"\xC3\x28\"}"));
    check("json: trailing garbage refused", !json_ok("{} x"));
    check("json: control char in string refused", !json_ok("{\"r\":\"a\nb\"}"));
    check("json: depth limit", !json_ok(std::string(40, '[') + std::string(40, ']')));

    // versions and URLs
    unsigned a[3], b[3];
    check("version 1.10.0 > 1.9.9", upd::parse_version("1.10.0", a) && upd::parse_version("1.9.9", b) && upd::newer(a, b));
    check("version equal is not newer", upd::parse_version("1.1.0", a) && upd::parse_version("1.1.0", b) && !upd::newer(a, b));
    check("version leading zero refused", !upd::parse_version("1.01.0", a));
    check("version 65536 refused", !upd::parse_version("65536.0.0", a));
    check("version with suffix refused", !upd::parse_version("1.0.0-rc", a));
    const std::string repo = "MShkolenko/algalon-launcher";
    check("url ok", upd::url_ok("https://github.com/MShkolenko/algalon-launcher/releases/download/v1.1.0/a.exe", repo));
    check("url other repo refused", !upd::url_ok("https://github.com/x/y/releases/download/v1/a.exe", repo));
    check("url .. refused", !upd::url_ok("https://github.com/MShkolenko/algalon-launcher/releases/download/../a.exe", repo));
    check("url extra segment refused", !upd::url_ok("https://github.com/MShkolenko/algalon-launcher/releases/download/v1/x/a.exe", repo));
    check("url http refused", !upd::url_ok("http://github.com/MShkolenko/algalon-launcher/releases/download/v1/a.exe", repo));

    // signature: the published test vector (throwaway key)
    std::string m, sig, tm, tsig, pub;
    bool have = read_file(L"..\\docs\\test-vector\\manifest.json", m) && read_file(L"..\\docs\\test-vector\\manifest.json.sig", sig) &&
                read_file(L"..\\docs\\test-vector\\manifest-tampered.json", tm) && read_file(L"..\\docs\\test-vector\\pubkey.hex", pub);
    while (!pub.empty() && (pub.back() == '\n' || pub.back() == '\r')) pub.pop_back();
    check("test vector found", have);
    check("signature: test vector verifies", have && upd::verify_signature(m, sig, pub));
    check("signature: tampered manifest fails", have && !upd::verify_signature(tm, sig, pub));
    check("signature: wrong key fails", have && !upd::verify_signature(m, sig, std::string(128, 'A')));
    check("signature: truncated signature fails", have && !upd::verify_signature(m, sig.substr(0, 40), pub));

    // network: a control request first; the network checks are skipped only when that control itself fails
    std::string body;
    bool online = upd::http_get(L"https://httpbin.org/bytes/2048", 4096, 20000, body) && body.size() == 2048;
    if (!online) {
        std::cout << "SKIP network checks: the control request to httpbin.org failed\n";
    } else {
        check("size limit: the same body fits a 2048-byte limit", upd::http_get(L"https://httpbin.org/bytes/2048", 2048, 20000, body) && body.size() == 2048);
        check("size limit: a 1024-byte limit refuses it", !upd::http_get(L"https://httpbin.org/bytes/2048", 1024, 20000, body) && body.empty());
        check("status: 404 refused", !upd::http_get(L"https://httpbin.org/status/404", 4096, 20000, body));
        check("redirect to HTTP refused", !upd::http_get(L"https://httpbin.org/redirect-to?url=http%3A%2F%2Fexample.com%2F", 1 << 20, 20000, body));
        // whole-request deadline: a server that answers after 10 s, a 3 s budget, twice in a row (the first worker is
        // abandoned while the second runs; both must finish on their own without disturbing anything)
        for (int k = 1; k <= 2; ++k) {
            ULONGLONG t0 = GetTickCount64();
            bool got = upd::http_get(L"https://httpbin.org/delay/10", 1 << 20, 3000, body);
            ULONGLONG ms = GetTickCount64() - t0;
            std::cout << "     (deadline call " << k << " took " << ms << " ms)\n";
            check(k == 1 ? "deadline: slow request fails within the budget" : "deadline: again, with an abandoned worker running",
                  !got && ms >= 2900 && ms < 3600 && body.empty());
        }
        check("after abandoned workers a normal request still works", upd::http_get(L"https://httpbin.org/bytes/16", 64, 20000, body) && body.size() == 16);
    }

    std::cout << (fails ? "FAILED " + std::to_string(fails) : std::string("ALL PASSED")) << "\n";
    return fails ? 1 : 0;
}
