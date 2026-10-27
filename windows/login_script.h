#pragma once
#include "saved_login.h"
#include "../shared/login_script.h"
#include <cstdio>

namespace saved_login {
inline std::string lua_literal(const std::wstring& text) {
    int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                  static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string bytes(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                        bytes.data(), size, nullptr, nullptr);
    std::string literal = "'";
    for (unsigned char c : bytes) {
        char escape[5];
        std::snprintf(escape, sizeof(escape), "\\%03u", static_cast<unsigned>(c));
        literal += escape;
    }
    literal += "'";
    SecureZeroMemory(bytes.data(), bytes.size());
    return literal;
}

inline std::string glue_script(const Login& login) {
    if (!valid(login)) return {};
    std::string script = ALGALON_LOGIN_SCRIPT;
    for (const auto& pair : {std::make_pair("@@ACCOUNT@@", &login.account),
                             std::make_pair("@@PASSWORD@@", &login.password)}) {
        size_t at = script.find(pair.first);
        if (at == std::string::npos || script.find(pair.first, at + 1) != std::string::npos) return {};
        script.replace(at, std::strlen(pair.first), lua_literal(*pair.second));
    }
    return script;
}
}  // namespace saved_login
