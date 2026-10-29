#pragma once
#include "saved_login.h"
#include <string>
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")

// The launcher's own login window (operator, 2026-10-29: the system CredUI prompt looked like Windows XP and stopped
// every start). Small, plain Win32, Russian: realm name and the launcher icon, Логин, Пароль, Запомнить, Играть, Отмена.
// With a saved login it shows for AUTO_MS and then plays by itself, unless the player touches it (a click or a key in
// the window); then it waits for Играть. Without a saved login it waits. Отмена keeps any saved login and continues
// with manual login in the game. Unticking Запомнить and pressing Играть removes the saved login.
namespace saved_login {

static const UINT AUTO_MS = 3000;

struct Ui {
    HWND wnd = nullptr, account = nullptr, password = nullptr, remember = nullptr, play = nullptr;
    HFONT font = nullptr;
    bool touched = false, done = false, played = false;
    std::wstring account_text, password_text;
    bool remember_checked = false;
};

enum { ID_ACCOUNT = 101, ID_PASSWORD, ID_REMEMBER, ID_PLAY, ID_CANCEL, ID_TIMER = 1 };

inline std::wstring text_of(HWND h) {
    int n = GetWindowTextLengthW(h);
    std::wstring s(static_cast<size_t>(n) + 1, L'\0');
    GetWindowTextW(h, &s[0], n + 1);
    s.resize(static_cast<size_t>(n));
    return s;
}

inline void finish(Ui* ui, bool played) {
    ui->played = played;
    if (played) {
        ui->account_text = text_of(ui->account);
        ui->password_text = text_of(ui->password);
        ui->remember_checked = SendMessageW(ui->remember, BM_GETCHECK, 0, 0) == BST_CHECKED;
    }
    // the password control's text is replaced before the window goes, so no copy stays in its buffer
    int n = GetWindowTextLengthW(ui->password);
    std::wstring blank(static_cast<size_t>(n), L' ');
    SetWindowTextW(ui->password, blank.c_str());
    ui->done = true;
    DestroyWindow(ui->wnd);
}

inline LRESULT CALLBACK login_proc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    Ui* ui = reinterpret_cast<Ui*>(GetWindowLongPtrW(h, GWLP_USERDATA));
    switch (msg) {
    case WM_NCCREATE:
        SetWindowLongPtrW(h, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams));
        break;
    case WM_TIMER:
        if (ui && w == ID_TIMER) {
            KillTimer(h, ID_TIMER);
            if (!ui->touched) finish(ui, true);
        }
        return 0;
    case WM_COMMAND:
        if (!ui) break;
        if (LOWORD(w) == ID_PLAY || LOWORD(w) == IDOK) {
            finish(ui, true);
            return 0;
        }
        if (LOWORD(w) == ID_CANCEL || LOWORD(w) == IDCANCEL) {
            finish(ui, false);
            return 0;
        }
        break;
    case WM_CLOSE:
        if (ui) finish(ui, false);
        return 0;
    case WM_CTLCOLORSTATIC:
        SetBkMode(reinterpret_cast<HDC>(w), TRANSPARENT);
        return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_WINDOW));
    }
    return DefWindowProcW(h, msg, w, l);
}

// Shows the window and fills `login`/`fill`. Same contract as before: ERROR_SUCCESS with fill=false means manual login.
inline DWORD choose(const std::wstring& target, const std::wstring& realm, Login& login, bool& fill) {
    fill = false;
    bool found = false;
    DWORD code = read(target, login, found);
    if (code != ERROR_SUCCESS) return code;

    HINSTANCE inst = GetModuleHandleW(nullptr);
    WNDCLASSEXW wc = {sizeof(wc)};
    wc.lpfnWndProc = login_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    wc.lpszClassName = L"AlgalonLoginWindow";
    RegisterClassExW(&wc);  // a second call in the same process fails harmlessly: the class is already there

    NONCLIENTMETRICSW ncm = {sizeof(ncm)};
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
    Ui ui;
    ui.font = CreateFontIndirectW(&ncm.lfMessageFont);

    const int W = 360, H = 210;
    RECT r = {0, 0, W, H};
    DWORD style = WS_CAPTION | WS_SYSMENU | WS_POPUP, ex = WS_EX_DLGMODALFRAME | WS_EX_TOPMOST;
    AdjustWindowRectEx(&r, style, FALSE, ex);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    int sx = (GetSystemMetrics(SM_CXSCREEN) - ww) / 2, sy = (GetSystemMetrics(SM_CYSCREEN) - wh) / 2;
    const std::wstring title = realm + L" - вход";
    ui.wnd = CreateWindowExW(ex, wc.lpszClassName, title.c_str(), style, sx, sy, ww, wh, nullptr, nullptr, inst, &ui);
    if (!ui.wnd) return GetLastError();

    auto make = [&](const wchar_t* cls, const wchar_t* text, DWORD st, int x, int y, int w, int h, int id) {
        HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | st, x, y, w, h, ui.wnd,
                                 reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), inst, nullptr);
        SendMessageW(c, WM_SETFONT, reinterpret_cast<WPARAM>(ui.font), TRUE);
        return c;
    };
    make(L"STATIC", L"Логин", 0, 20, 22, 70, 20, 0);
    ui.account = make(L"EDIT", found ? login.account.c_str() : L"", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL, 95, 18, 245, 26,
                      ID_ACCOUNT);
    make(L"STATIC", L"Пароль", 0, 20, 62, 70, 20, 0);
    ui.password = make(L"EDIT", found ? login.password.c_str() : L"",
                       WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, 95, 58, 245, 26, ID_PASSWORD);
    ui.remember = make(L"BUTTON", L"Запомнить", WS_TABSTOP | BS_AUTOCHECKBOX, 95, 98, 200, 22, ID_REMEMBER);
    SendMessageW(ui.remember, BM_SETCHECK, BST_CHECKED, 0);
    ui.play = make(L"BUTTON", L"Играть", WS_TABSTOP | BS_DEFPUSHBUTTON, 130, 150, 100, 32, ID_PLAY);
    make(L"BUTTON", L"Отмена", WS_TABSTOP | BS_PUSHBUTTON, 240, 150, 100, 32, ID_CANCEL);
    if (found) {
        SecureZeroMemory(&login.password[0], login.password.size() * sizeof(wchar_t));
        login.password.clear();
    }

    ShowWindow(ui.wnd, SW_SHOW);
    SetForegroundWindow(ui.wnd);
    SetFocus(found ? ui.play : ui.account);
    if (found) SetTimer(ui.wnd, ID_TIMER, AUTO_MS, nullptr);

    MSG msg;
    while (!ui.done && GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // any key or click in the window means the player is changing something: no automatic start
        if (msg.message == WM_KEYDOWN || msg.message == WM_LBUTTONDOWN || msg.message == WM_RBUTTONDOWN) {
            if (!ui.touched) {
                ui.touched = true;
                KillTimer(ui.wnd, ID_TIMER);
            }
        }
        if (IsDialogMessageW(ui.wnd, &msg)) continue;  // Tab, Enter = Играть, Esc = Отмена
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    DeleteObject(ui.font);

    struct Wipe {
        std::wstring& s;
        ~Wipe() {
            if (!s.empty()) SecureZeroMemory(&s[0], s.size() * sizeof(wchar_t));
        }
    } wipe{ui.password_text};
    if (!ui.played) return ERROR_SUCCESS;  // Отмена: manual login, a saved login stays
    login = {ui.account_text, ui.password_text};
    if (!valid(login)) {
        SecureZeroMemory(&login.password[0], login.password.size() * sizeof(wchar_t));
        login = {};
        return ERROR_INVALID_DATA;
    }
    code = ui.remember_checked ? write(target, login) : (found ? forget(target) : ERROR_SUCCESS);
    if (code == ERROR_SUCCESS) fill = true;
    return code;
}
}  // namespace saved_login
