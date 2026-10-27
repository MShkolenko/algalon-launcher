#pragma once
#include <windows.h>
#include <wincred.h>
#include <cstring>
#include <string>
#include <utility>

namespace saved_login {
struct Login {
    std::wstring account, password;
};

inline bool valid_text(const std::wstring& text, int maximum_units) {
    if (text.empty() || text.size() > static_cast<size_t>(maximum_units)) return false;
    for (wchar_t c : text)
        if (c < 32 || (c >= 127 && c <= 159)) return false;
    int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                   static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    return bytes > 0;
}

inline bool valid(const Login& login) {
    return valid_text(login.account, 320) && valid_text(login.password, 128);
}

// Target names are derived from the selected realm profile, never from an account.
inline DWORD read(const std::wstring& target, Login& login, bool& found) {
    found = false;
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
        DWORD code = GetLastError();
        return code == ERROR_NOT_FOUND ? ERROR_SUCCESS : code;
    }
    Login value;
    bool shape = credential->UserName && credential->CredentialBlob
        && credential->CredentialBlobSize % sizeof(wchar_t) == 0
        && credential->CredentialBlobSize <= 256;
    if (shape) {
        value.account = credential->UserName;
        value.password.resize(credential->CredentialBlobSize / sizeof(wchar_t));
        std::memcpy(value.password.data(), credential->CredentialBlob, credential->CredentialBlobSize);
    }
    if (credential->CredentialBlob)
        SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
    CredFree(credential);
    if (!shape || !valid(value)) return ERROR_INVALID_DATA;
    login = std::move(value);
    found = true;
    return ERROR_SUCCESS;
}

inline DWORD write(const std::wstring& target, const Login& login) {
    if (!valid(login)) return ERROR_INVALID_DATA;
    CREDENTIALW credential = {};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(target.c_str());
    credential.UserName = const_cast<wchar_t*>(login.account.c_str());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<wchar_t*>(login.password.data()));
    credential.CredentialBlobSize = static_cast<DWORD>(login.password.size() * sizeof(wchar_t));
    // Despite its name this persists only for the current Windows user on this PC.
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0) ? ERROR_SUCCESS : GetLastError();
}

inline DWORD forget(const std::wstring& target) {
    if (CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0)) return ERROR_SUCCESS;
    DWORD code = GetLastError();
    return code == ERROR_NOT_FOUND ? ERROR_SUCCESS : code;
}
}  // namespace saved_login
