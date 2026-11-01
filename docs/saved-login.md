# Remembered server login

The Mac candidate adds a native Swift/AppKit form with account, secure password,
Remember on this Mac, Play, Manual Login, Cancel and Forget Saved Login. It fills
only the isolated client. Log In remains an explicit action in WoW.

The native Mac path passed field targeting, saved-entry relaunch, account/realm
authentication and visual world loading on client1.60.1.70630 on2026-10-27.
See [the acceptance record](../macos/reports/2026-10-27-native-login.md) for the
successful run, a separate realm disconnect and remaining distribution limits.

Candidate1.2.2 repairs the Secure Input regression introduced by1.2.1. The installed
Mac build passed saved-entry autofill, SRP/account and realm authentication, one
validated region-key installation, the existing character list, visual world loading
and clean exit on release70707 on2026-11-01.35 native multi-process safety checks
pass. See the [repair and acceptance record](../macos/reports/2026-11-01-native-input-repair.md)
for exact scope, signing/update gates and remaining resource costs.

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
The historical local1.2.0 candidate used an existing Apple Development identity; its
stable designated requirement survived changed builds and repeated launches without
new Keychain prompts. That personal-signed application is not distributed.
The owner explicitly chose ad-hoc distribution without Developer ID or notarization
and accepts renewed approval after binary changes. Production update-manifest signing
remains a separate owner-controlled gate.

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
coordinate conversion, the capture content rectangle must match the window's
screen-space edges within one point; its origin is not added a second time.
Before every
click/key event, the native process path, PID, foreground application and current
permissions must match. Mouse input goes through WindowServer HID with an
additional effective hit-target and exact window-ID/PID/bounds check. Keyboard input uses PID-targeted
CoreGraphics Unicode events. A correct remembered account is retained. Otherwise,
a nonsecret marker must first appear in the account field before the real account
is entered and read back. Before any password is typed, distinct nonsecret `W` and
`i` probes must produce two matching compact mask glyphs in the password band;
erasing both must restore an empty band. The expected account must remain unchanged.
No secret enters this visual focus check. Final account readback must still match.
Filling waits at most90seconds for the recognized screen. The existing isolated
native module uses an AppKit local event filter, which remains observable under
Secure Input. An inherited anonymous socket carries only window identity, random
nonces, one-event permits and acknowledgements; no account/password text crosses it.
The filter validates active/key window and geometry, cancels on foreign input
including Tab/click/movement, and drops queued own input after cancellation, timeout
or launcher EOF. A short-lived external mouse tap also cancels outside-window input.
Before secret entry, actual nonsecret key/click acknowledgements, masked-field proof,
probe erasure and Secure Input are required. Every text scalar uses a tagged key-down
and empty key-up pair and waits for native delivery acknowledgement. Secure Input is
never disabled. CoreGraphics addresses a PID, not a game widget: focus checks cannot
make the game's own programmatic widget changes atomic with delivery.
A target/focus/permission change stops input; the saved entry is retained. Finish
manually after an interrupted attempt rather than retrying automatically.

The native form uses a nonblocking modal session within the AppKit event loop.
A hidden permission dialog or a blocking modal on the async main executor must
not stall Play. Successful completion removes the local filter and external tap.
Interruption removes the tap/socket/notifications; an inert local filter remains
to reject late own events while allowing manual input and paired empty releases.
The native channel is enabled only for this launch's verified private executable.

The advertised client glue-script arguments failed actual stock-client controls;
the unused prototype renderers/template have been removed. Client integrity,
TLS/name checks, official-client isolation and existing updater checks remain.

## Windows scope

The Windows implementation is maintained separately by the owner in this repository.
Generic credentials use CredReadW/CredWriteW/CredDeleteW for the current Windows
user on this PC. The owner reports live full auto-login and multi-account acceptance
in Windows1.2.0; see [the Windows report](https://github.com/MShkolenko/algalon-mac/issues/1#issuecomment-6490912282).
The Mac continuation preserves the owner's Windows tree unchanged.

## Validation

Run `bash macos/Tests/run-login.sh` for actual disposable Keychain CRUD/update/delete,
exact Unicode/punctuation, invalid records, realm separation and label/layout
admission controls. The test process alone disables Keychain interaction and
removes only its own fictional entries. Run the existing smoke and updater suites
before delivery; build and verify both architecture slices and signatures.
`bash macos/Tests/run-login-safety.sh` independently renders masked and clear fields,
dead targets, erasure failures and changed geometry with CoreText. The native
`Tests/login-events` fixture uses fictional input only for Secure Input delivery,
third-process Tab/click/movement cancellation, key-window and geometry changes,
a stalled target, EOF, and paired releases after interruption. Build it with
`bash macos/Tests/build-login-events.sh`. It runs autonomously with a controller,
separate AppKit target, third input process and the production channel/filter/posting
functions. It requires its existing Accessibility/Screen Recording permissions.
`bash macos/Tests/run-input-channel.sh` exercises both real socket receivers for
scope, nonce, replay, frame validation, fragmentation, timeout and EOF. The region
monitor fixture exercises a real isolated native child while UI completion is suspended.
It also covers40 normal child exits and rejects a live executable-identity mismatch.

The native Windows CI run40519196006 on sourcebde6e3c passed real CredMan CRUD,
host/updater controls and both profile builds. It is hosted-runner evidence,
not interactive Windows game acceptance. Later changes need their own CI result.

Mac candidate1.2.0(8) was exercised with the native form, granted permissions,
distinct-account readback, a nonsecret password-focus control and repeated saved-
entry launch. Intended-account SRP and realm authentication, one key installation,
character list, world/spell loading100% and normal exit passed at21:32–21:34MSK.
One earlier run authenticated the account but disconnected at the realm stage;
the cause is open and is not attributed to password filling without evidence.
Clean-Mac installation and Intel/old-OS execution are not established by these Mac results.
The new review fixes require their own acceptance; the October27 result does not
prove that later code has passed. Notarization is outside the owner's chosen scope.
