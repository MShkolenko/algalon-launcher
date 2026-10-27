# Remembered server login

The Mac candidate adds a native Swift/AppKit form with account, secure password,
Remember on this Mac, Play, Manual Login, Cancel and Forget Saved Login. It fills
only the isolated client. Log In remains an explicit action in WoW.

The native Mac path passed field targeting, saved-entry relaunch, account/realm
authentication and visual world loading on client1.60.1.70630 on2026-10-27.
See [the acceptance record](../macos/reports/2026-10-27-native-login.md) for the
successful run, a separate realm disconnect and remaining distribution limits.

## Storage and exact input

macOS uses SecItem generic passwords in the user's login Keychain, scoped to the
profile and realm. Remember is optional. Cancel and Manual Login retain a saved
entry; Forget or submitting with Remember disabled removes only the exact realm
entry. Store failures retain the record and offer manual login. Passwords are
preserved exactly, including punctuation and whitespace. Control characters are
rejected; limits are320 account and128 password UTF-16 units.

Very long or visually ambiguous account names can fail screen readback safely; use
Manual Login in that case. Wait for filling to finish before interacting with WoW.

No credentials are written into arguments, environment variables, configuration,
logs, source, screenshots, tests or build inputs. Saved credentials are held in
the OS Keychain and transient process memory. The launcher does not use the
clipboard to fill WoW.

Default distribution builds are ad-hoc signed and lack a provisioning-profile-authorized
Data Protection Keychain access group. They use the file-based login Keychain
with its default application access controls. A changed ad-hoc binary has a new
hash-based identity and can require Keychain/TCC approval again. Always Allow
for one binary is not a stable release-signing identity. Do not broaden ACLs,
add arbitrary trusted applications, or disable OS checks to suppress prompts.
The installed local candidate uses an existing Apple Development identity; its
stable designated requirement survived changed builds and repeated launches without
new Keychain prompts. That personal-signed application is not distributed.
A stable Developer ID release-signing identity remains an owner distribution
prerequisite; it is separate from signing the update manifest.

## Native Mac field filling

Automatic filling requires macOS14 or later plus the launcher's own Accessibility
and Screen Recording permissions. macOS12/13 retain manual login. Missing rights
are shown explicitly, with retry/manual/cancel paths; the launcher does not silently
exit after a failed preflight. No permission is granted programmatically.

ScreenCaptureKit captures only the selected private game window, at bounded
resolution, without audio. Vision processes images locally and returns only the
four fixed English/Russian login labels plus exact expected-account match positions.
Images and arbitrary OCR text are not
saved or transmitted. Geometry must be unique, ordered and aligned. Before every
click/key event, the native process path, PID, foreground application and current
permissions must match. Mouse input goes through WindowServer HID with an
additional topmost window-ID/PID/bounds check. Keyboard input uses PID-targeted
CoreGraphics Unicode events. A correct remembered account is retained. Otherwise,
a nonsecret marker must first appear in the account field before the real account
is entered and read back. A second nonsecret probe checks that the account stays
unchanged after focusing the password field, before any secret is typed. The final
account readback must still match. A failed readback clears the focused field
and stops filling. Filling waits at most90seconds for the recognized screen.
A target/focus/permission change stops input; the saved entry is retained.

The native form uses a nonblocking modal session within the AppKit event loop.
A hidden permission dialog or a blocking modal on the async main executor must
not stall Play. There is no resident login observer after filling finishes.

The advertised client glue-script arguments failed actual stock-client controls;
the unused prototype renderers/template have been removed. Client integrity,
TLS/name checks, official-client isolation and existing updater checks remain.

## Windows scope

The same repository contains native C++ CredMan storage and credential UI adapters.
Generic credentials use CredReadW/CredWriteW/CredDeleteW for the current Windows
user on this PC. The adapters are not yet connected to Windows game input.
Do not claim working Windows autofill or ship invented client flags.

## Validation

Run `bash macos/Tests/run-login.sh` for actual disposable Keychain CRUD/update/delete,
exact Unicode/punctuation, invalid records, realm separation and label/layout
admission controls. The test process alone disables Keychain interaction and
removes only its own fictional entries. Run the existing smoke and updater suites
before delivery; build and verify both architecture slices and signatures.

The native Windows CI run40519196006 on sourcebde6e3c passed real CredMan CRUD,
host/updater controls and both profile builds. It is hosted-runner evidence,
not interactive Windows game acceptance. Later changes need their own CI result.

Mac candidate1.2.0(8) was exercised with the native form, granted permissions,
distinct-account readback, a nonsecret password-focus control and repeated saved-
entry launch. Intended-account SRP and realm authentication, one key installation,
character list, world/spell loading100% and normal exit passed at21:32–21:34MSK.
One earlier run authenticated the account but disconnected at the realm stage;
the cause is open and is not attributed to password filling without evidence.
Windows interactive filling, clean-Mac installation, Intel/old-OS execution and
notarized distribution are not established by these Mac results.
