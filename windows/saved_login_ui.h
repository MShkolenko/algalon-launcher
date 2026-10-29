#pragma once
#include "saved_login.h"
#include <commctrl.h>
#include <string>
#include <vector>
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "comctl32.lib")
// Common Controls 6: the current Windows look for buttons, fields, the check box and the list (operator, 2026-10-29:
// the classic controls looked decades old). Applies to every window and message box of the launcher.
#pragma comment(linker, "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' "\
                        "processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

// The launcher's own login window (operator, 2026-10-29: the system CredUI prompt looked like Windows XP and stopped
// every start). Small, plain Win32, Russian: realm name and the launcher icon, Логин (a list of every saved login, or
// a new one typed in), Пароль, Запомнить, Играть, Отмена.
//   - Choosing a saved login from the list puts its password in; typing or changing the login by hand clears it.
//   - With a saved login it shows for AUTO_MS and then plays by itself, unless the player touches it (a key, a mouse
//     button or the wheel on it); then it waits for Играть. Without a saved login it waits.
//   - Играть with Запомнить saves that login (one entry per account; the last one used comes first next time);
//     Играть without Запомнить removes that account's saved entry. Отмена keeps everything and goes to manual login.
namespace saved_login {

static const UINT AUTO_MS = 3000;

struct Ui {
    HWND wnd = nullptr, account = nullptr, password = nullptr, remember = nullptr;
    HFONT font = nullptr;
    bool touched = false, done = false, played = false;
    std::vector<Login> saved;
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

// Replaces the password control's text with blanks, then empties it, so no copy stays in its buffer.
inline void clear_password(Ui* ui) {
    int n = GetWindowTextLengthW(ui->password);
    std::wstring blank(static_cast<size_t>(n), L' ');
    SetWindowTextW(ui->password, blank.c_str());
    SetWindowTextW(ui->password, L"");
}

inline void finish(Ui* ui, bool played) {
    ui->played = played;
    if (played) {
        ui->account_text = text_of(ui->account);
        ui->password_text = text_of(ui->password);
        ui->remember_checked = SendMessageW(ui->remember, BM_GETCHECK, 0, 0) == BST_CHECKED;
    }
    clear_password(ui);
    ui->done = true;
    DestroyWindow(ui->wnd);
}

inline void stop_auto(Ui* ui) {
    if (!ui->touched) {
        ui->touched = true;
        KillTimer(ui->wnd, ID_TIMER);
    }
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
        if (LOWORD(w) == ID_ACCOUNT && HIWORD(w) == CBN_SELCHANGE) {  // a saved login chosen: its password goes in
            LRESULT i = SendMessageW(ui->account, CB_GETCURSEL, 0, 0);
            clear_password(ui);
            if (i >= 0 && static_cast<size_t>(i) < ui->saved.size())
                SetWindowTextW(ui->password, ui->saved[static_cast<size_t>(i)].password.c_str());
            return 0;
        }
        if (LOWORD(w) == ID_ACCOUNT && HIWORD(w) == CBN_EDITCHANGE) {  // the login typed by hand: the password goes
            clear_password(ui);
            return 0;
        }
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

inline void wipe_all(std::vector<Login>& v) {
    for (Login& l : v)
        if (!l.password.empty()) SecureZeroMemory(&l.password[0], l.password.size() * sizeof(wchar_t));
    v.clear();
}

// `prefix` is the realm's credential prefix. Fills `login`/`fill`. ERROR_SUCCESS with fill=false means manual login.
inline DWORD choose(const std::wstring& prefix, const std::wstring& realm, Login& login, bool& fill) {
    fill = false;
    // the one entry of the earlier single-login version moves to the per-account form
    bool old_found = false;
    Login old;
    if (read(prefix, old, old_found) == ERROR_SUCCESS && old_found) {
        if (write(account_target(prefix, old.account), old) == ERROR_SUCCESS) forget(prefix);
        SecureZeroMemory(&old.password[0], old.password.size() * sizeof(wchar_t));
    }
    Ui ui;
    struct WipeUi {
        Ui& u;
        ~WipeUi() {
            wipe_all(u.saved);
            if (!u.password_text.empty()) SecureZeroMemory(&u.password_text[0], u.password_text.size() * sizeof(wchar_t));
        }
    } wipe_ui{ui};
    DWORD code = list(prefix, ui.saved);
    if (code != ERROR_SUCCESS) return code;
    bool found = !ui.saved.empty();

    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);
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
    ui.font = CreateFontIndirectW(&ncm.lfMessageFont);

    const int W = 380, H = 200;
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
    make(WC_STATICW, L"Логин", SS_CENTERIMAGE, 24, 24, 70, 26, 0);
    ui.account = make(WC_COMBOBOXW, L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWN | CBS_AUTOHSCROLL, 100, 24, 256, 200,
                      ID_ACCOUNT);
    for (const Login& l : ui.saved) SendMessageW(ui.account, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(l.account.c_str()));
    make(WC_STATICW, L"Пароль", SS_CENTERIMAGE, 24, 64, 70, 26, 0);
    ui.password = make(WC_EDITW, L"", WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, 100, 64, 256, 26, ID_PASSWORD);
    ui.remember = make(WC_BUTTONW, L"Запомнить", WS_TABSTOP | BS_AUTOCHECKBOX, 100, 102, 200, 24, ID_REMEMBER);
    SendMessageW(ui.remember, BM_SETCHECK, BST_CHECKED, 0);
    HWND play = make(WC_BUTTONW, L"Играть", WS_TABSTOP | BS_DEFPUSHBUTTON, 146, 148, 100, 30, ID_PLAY);
    make(WC_BUTTONW, L"Отмена", WS_TABSTOP | BS_PUSHBUTTON, 256, 148, 100, 30, ID_CANCEL);
    if (found) {  // the last login used comes first (CB_ADDSTRING keeps the order: the combo is not sorted)
        SendMessageW(ui.account, CB_SETCURSEL, 0, 0);
        SetWindowTextW(ui.password, ui.saved[0].password.c_str());
    }

    ShowWindow(ui.wnd, SW_SHOW);
    SetForegroundWindow(ui.wnd);
    SetFocus(found ? play : ui.account);
    if (found) SetTimer(ui.wnd, ID_TIMER, AUTO_MS, nullptr);

    MSG msg;
    while (!ui.done && GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // any key, mouse button or wheel on the window means the player is changing something: no automatic start
        UINT m = msg.message;
        bool input = m == WM_KEYDOWN || m == WM_SYSKEYDOWN || m == WM_LBUTTONDOWN || m == WM_RBUTTONDOWN ||
                     m == WM_MBUTTONDOWN || m == WM_XBUTTONDOWN || m == WM_NCLBUTTONDOWN || m == WM_NCRBUTTONDOWN ||
                     m == WM_NCMBUTTONDOWN || m == WM_NCXBUTTONDOWN || m == WM_MOUSEWHEEL || m == WM_MOUSEHWHEEL;
        if (input && (msg.hwnd == ui.wnd || IsChild(ui.wnd, msg.hwnd))) stop_auto(&ui);
        if (IsDialogMessageW(ui.wnd, &msg)) continue;  // Tab, Enter = Играть, Esc = Отмена
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    DeleteObject(ui.font);

    if (!ui.played) return ERROR_SUCCESS;  // Отмена: manual login, saved logins stay
    login = {ui.account_text, ui.password_text};
    if (!valid(login)) {
        if (!login.password.empty()) SecureZeroMemory(&login.password[0], login.password.size() * sizeof(wchar_t));
        login = {};
        return ERROR_INVALID_DATA;
    }
    const std::wstring target = account_target(prefix, login.account);
    code = ui.remember_checked ? write(target, login) : forget(target);
    if (code == ERROR_SUCCESS) fill = true;
    return code;
}
}  // namespace saved_login
