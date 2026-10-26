// Test of the launcher's hosts logic on sample files; never touches the real hosts file.
// Build: cl /nologo /std:c++17 /EHsc /DUNICODE /D_UNICODE test_hosts.cpp /link /SUBSYSTEM:CONSOLE shell32.lib ole32.lib user32.lib crypt32.lib ws2_32.lib
#include "algalon-launcher.cpp"
#include <iostream>

static int fails = 0;
static void check(const char* name, bool ok) {
    std::cout << (ok ? "PASS " : "FAIL ") << name << "\n";
    if (!ok) ++fails;
}

static std::string rebuild(const std::string& raw, bool& right, bool& wrong, bool& encoded) {
    std::string out;
    encoded = hosts_scan(raw, "algalon.actual.battle.net", right, wrong, "194.87.95.220", &out);
    return out;
}

int main() {
    const std::string H = "algalon.actual.battle.net";
    bool r, w, e;

    // 1. ordinary ANSI hosts, a cp1251 Cyrillic comment, no line of ours: kept byte for byte
    std::string a = "# hosts\r\n127.0.0.1 localhost\r\n# \xcf\xf0\xe8\xe2\xe5\xf2 cp1251\r\n";
    std::string o = rebuild(a, r, w, e);
    check("ansi kept byte for byte, nothing of ours", e && !r && !w && o == a);

    // 2. our host alone with an old address: the line goes
    std::string b = "127.0.0.1 localhost\r\n192.168.0.240 algalon.actual.battle.net   # old\r\n";
    o = rebuild(b, r, w, e);
    check("old address detected as wrong", e && !r && w);
    check("old line removed, other line kept", o == "127.0.0.1 localhost\r\n");

    // 3. our host shares a line with another name: the other name survives
    std::string c = "10.0.0.1 router.local algalon.actual.battle.net other.lan # mine\r\n";
    o = rebuild(c, r, w, e);
    check("shared line keeps the other names and the comment", o == "10.0.0.1 router.local other.lan # mine\r\n");

    // 4. UTF-8 with BOM: BOM kept
    std::string d = "\xEF\xBB\xBF" "127.0.0.1 localhost\r\n";
    o = rebuild(d, r, w, e);
    check("utf-8 BOM preserved", e && o == d);

    // 5. UTF-16 LE: refused, not rewritten
    std::string f("\xFF\xFE" "1\0" "2\0", 6);
    o = rebuild(f, r, w, e);
    check("utf-16 refused", !e);

    // 6. already correct: right, nothing wrong
    std::string g = "127.0.0.1 localhost\r\n194.87.95.220 algalon.actual.battle.net   # Algalon\r\n";
    o = rebuild(g, r, w, e);
    check("correct file recognized", e && r && !w);

    // 7. case-insensitive host, tab separated, IPv6 line untouched
    std::string i = "::1 localhost\r\n1.2.3.4\tALGALON.actual.battle.net\r\n";
    o = rebuild(i, r, w, e);
    check("tab and case handled, IPv6 line kept", e && w && o == "::1 localhost\r\n");

    // 8. file without trailing newline: our appended line must start on its own line (hosts_fix adds \r\n)
    std::string j = "127.0.0.1 localhost";
    o = rebuild(j, r, w, e);
    check("no trailing newline kept as is for the append step", e && o == j);

    // 9. overwrite_in_place on a temp copy keeps the file and replaces its content exactly
    wchar_t tmpdir[MAX_PATH];
    GetTempPathW(MAX_PATH, tmpdir);
    wstr t = wstr(tmpdir) + L"algalon-hosts-test.txt";
    write_file(t, "a long original content line\r\nsecond\r\n");
    bool ow = overwrite_in_place(t, "short\r\n");
    std::string back;
    read_file(t, back);
    check("overwrite_in_place replaces and truncates", ow && back == "short\r\n");
    DeleteFileW(t.c_str());

    // 9b. one handle held for read+write blocks another writer for its whole life (the round 3 race)
    write_file(t, "127.0.0.1 localhost\r\n");
    HANDLE held = CreateFileW(t.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    std::string seen;
    bool read_ok = held != INVALID_HANDLE_VALUE && handle_read_all(held, seen) && seen == "127.0.0.1 localhost\r\n";
    HANDLE other = CreateFileW(t.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    bool blocked = other == INVALID_HANDLE_VALUE;
    if (!blocked) CloseHandle(other);
    std::string after;
    bool rw_ok = handle_write_all(held, "new\r\n") && handle_read_all(held, after) && after == "new\r\n";
    if (held != INVALID_HANDLE_VALUE) CloseHandle(held);
    check("held handle reads the whole file", read_ok);
    check("another writer is refused while held", blocked);
    check("write and read back through the same handle", rw_ok);
    DeleteFileW(t.c_str());

    // 9c. a read-only file can still be opened for reading (the path taken when hosts is already correct)
    write_file(t, "194.87.95.220 algalon.actual.battle.net\r\n");
    SetFileAttributesW(t.c_str(), FILE_ATTRIBUTE_READONLY);
    HANDLE rw = CreateFileW(t.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    bool rw_refused = rw == INVALID_HANDLE_VALUE;
    if (!rw_refused) CloseHandle(rw);
    HANDLE ro = CreateFileW(t.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    std::string ro_data;
    bool ro_ok = ro != INVALID_HANDLE_VALUE && handle_read_all(ro, ro_data);
    if (ro != INVALID_HANDLE_VALUE) CloseHandle(ro);
    bool r2, w2;
    bool correct = ro_ok && hosts_scan(ro_data, "algalon.actual.battle.net", r2, w2, "194.87.95.220", nullptr) && r2 && !w2;
    check("read-only hosts refuses a write handle", rw_refused);
    check("read-only hosts is still read and found correct", correct);
    SetFileAttributesW(t.c_str(), FILE_ATTRIBUTE_NORMAL);
    DeleteFileW(t.c_str());

    // 10. argument validation for the elevated helper
    check("valid args accepted", valid_setup_args(L"194.87.95.220", L"algalon.actual.battle.net"));
    check("bad ip rejected", !valid_setup_args(L"194.87.95", L"algalon.actual.battle.net"));
    check("foreign host rejected", !valid_setup_args(L"1.2.3.4", L"evil.example.com"));
    check("host with space rejected", !valid_setup_args(L"1.2.3.4", L"a b.actual.battle.net"));

    std::cout << (fails ? "FAILURES: " : "ALL PASSED") << (fails ? std::to_string(fails) : "") << "\n";
    return fails;
}
