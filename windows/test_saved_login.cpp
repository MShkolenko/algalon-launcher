#include "login_script.h"
#include "saved_login_ui.h"
#include <cstdio>

static void check(bool good) {
    if (!good) {
        std::fputs("FAIL: saved-login contract\n", stderr);
        ExitProcess(1);
    }
}

int main() {
    const std::wstring target = L"AlgalonLauncher/tests/" + std::to_wstring(GetCurrentProcessId())
        + L"/" + std::to_wstring(GetTickCount64());
    const saved_login::Login first{L"fictional@example.invalid", L"Ab12\"\\.\u00e9"};
    const saved_login::Login second{L"other@example.invalid", L"Replacement."};
    check(saved_login::valid(first));
    check(saved_login::valid({L"fake", std::wstring(128, L'x')}));
    check(!saved_login::valid({L"fake", std::wstring(129, L'x')}));
    const auto script = saved_login::glue_script({L"Ab12", L"'\\\u00e9."});
    check(script.find("local account, password = '\\065\\098\\049\\050', '\\039\\092\\195\\169\\046'")
          != std::string::npos);
    check(script.find("@@") == std::string::npos && script.find('"') == std::string::npos);
    check(!saved_login::valid({L"", L"abc"}));
    check(!saved_login::valid({L"fake", L""}));
    check(!saved_login::valid({L"fake", L"abc\n"}));
    check(!saved_login::valid({L"fake", std::wstring(L"abc\0", 4)}));
    check(!saved_login::valid({L"fake", std::wstring(513, L'\u00e9')}));
    check(!saved_login::valid({L"fake", std::wstring(1, 0xd800)}));
    saved_login::Login read;
    bool found = true;
    check(saved_login::read(target, read, found) == ERROR_SUCCESS && !found);
    check(saved_login::write(target, first) == ERROR_SUCCESS);
    check(saved_login::write(target + L"/other", first) == ERROR_SUCCESS);
    check(saved_login::read(target, read, found) == ERROR_SUCCESS && found
          && read.account == first.account && read.password == first.password);
    check(saved_login::write(target, second) == ERROR_SUCCESS);
    check(saved_login::read(target, read, found) == ERROR_SUCCESS && found
          && read.account == second.account && read.password == second.password);
    check(saved_login::read(target + L"/other", read, found) == ERROR_SUCCESS && found
          && read.password == first.password);
    const auto malformed_target = target + L"/malformed";
    CREDENTIALW malformed = {};
    unsigned char byte = 65;
    malformed.Type = CRED_TYPE_GENERIC;
    malformed.TargetName = const_cast<wchar_t*>(malformed_target.c_str());
    malformed.UserName = const_cast<wchar_t*>(L"fictional@example.invalid");
    malformed.CredentialBlob = &byte;
    malformed.CredentialBlobSize = 1;
    malformed.Persist = CRED_PERSIST_LOCAL_MACHINE;
    check(CredWriteW(&malformed, 0));
    check(saved_login::read(malformed_target, read, found) == ERROR_INVALID_DATA && !found);
    check(saved_login::forget(malformed_target) == ERROR_SUCCESS);
    check(saved_login::write(target, {L"fake", L"bad\n"}) == ERROR_INVALID_DATA);
    check(saved_login::read(target, read, found) == ERROR_SUCCESS && found
          && read.password == second.password);
    check(saved_login::forget(target) == ERROR_SUCCESS);
    check(saved_login::forget(target) == ERROR_SUCCESS);
    check(saved_login::forget(target + L"/other") == ERROR_SUCCESS);
    check(saved_login::read(target, read, found) == ERROR_SUCCESS && !found);
    std::puts("PASS: real CredMan CRUD, exact Unicode/password punctuation, validation, realm isolation");
}
