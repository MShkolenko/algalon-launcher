#pragma once
#include "saved_login.h"
#include <algorithm>
#include <iterator>

namespace saved_login {
// Cancel preserves any existing credential and continues with manual game login.
inline DWORD choose(const std::wstring& target, const std::wstring& realm, Login& login, bool& fill) {
    fill = false;
    bool found = false;
    DWORD code = read(target, login, found);
    if (code != ERROR_SUCCESS) return code;
    wchar_t account[CREDUI_MAX_USERNAME_LENGTH + 1] = {};
    wchar_t password[CREDUI_MAX_PASSWORD_LENGTH + 1] = {};
    if (found) {
        std::copy(login.account.begin(), login.account.end(), account);
        std::copy(login.password.begin(), login.password.end(), password);
    }
    BOOL remember = found;
    const std::wstring title = realm + L" login";
    CREDUI_INFOW info = {};
    info.cbSize = sizeof(info);
    info.pszCaptionText = title.c_str();
    info.pszMessageText = L"Fill the game login fields, then click Log In in WoW. Use only your server account. "
        L"Cancel continues with manual login. Uncheck Remember to remove a previously saved login.";
    code = CredUIPromptForCredentialsW(&info, target.c_str(), nullptr, 0,
        account, static_cast<ULONG>(std::size(account)), password, static_cast<ULONG>(std::size(password)),
        &remember, CREDUI_FLAGS_GENERIC_CREDENTIALS | CREDUI_FLAGS_ALWAYS_SHOW_UI
            | CREDUI_FLAGS_DO_NOT_PERSIST | CREDUI_FLAGS_SHOW_SAVE_CHECK_BOX);
    if (code == ERROR_SUCCESS) login = {account, password};
    SecureZeroMemory(password, sizeof(password));
    if (code == ERROR_CANCELLED) return ERROR_SUCCESS;
    if (code != ERROR_SUCCESS) return code;
    if (!valid(login)) return ERROR_INVALID_DATA;
    code = remember ? write(target, login) : (found ? forget(target) : ERROR_SUCCESS);
    if (code == ERROR_SUCCESS) fill = true;
    return code;
}
}  // namespace saved_login
