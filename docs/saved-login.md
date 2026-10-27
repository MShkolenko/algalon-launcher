# Remembered login: implementation checkpoint

This branch is a work in progress. The existing launcher startup does **not** call
the new credential dialog or pass the candidate glue script to the game yet.
Do not release it as working autofill until the actual release client test passes.

The operator requested the same optional remembered-login behavior on macOS and
Windows. Native storage and UI adapters live in this one canonical repository;
`shared/login_script.h` is the single candidate implementation for filling the
game fields. It never clicks Log In, changes the portal or disables verification.

## Native storage

- macOS uses SecItem generic passwords in the user's login Keychain. The current
  launcher is ad-hoc signed and has no provisioning profile authorizing a Data
  Protection Keychain access group. It does not broaden the default Keychain ACL.
  A later changed ad-hoc binary may require a native Keychain confirmation.
- Windows uses generic credentials through CredReadW/CredWriteW/CredDeleteW.
  These are standard Win32 APIs, with no additional library installation.
  `CRED_PERSIST_LOCAL_MACHINE` persists for the current Windows user on this PC;
  it does not share the entry with other Windows users.
- The production caller must supply a stable service/target scoped to the chosen
  launcher profile and realm. There is one saved account per realm.
- Passwords are preserved exactly, including leading/trailing punctuation and
  whitespace. Control characters are rejected. Account length is at most 320
  UTF-16 code units; password length is at most 128, matching the current UI limit.
- Remember is explicit. Manual login/cancel preserves an existing saved entry.
  Forget or disabling Remember removes only this launcher's exact realm entry.
  An OS-store error retains the entry and permits manual game login.
- No actual operator account, password or other runtime authentication material
  belongs in source, logs, tests, release notes or build inputs. Tests use only
  disposable fictional records and remove those exact records afterward.

## Candidate client input path — not accepted yet

The current client binary's usage text advertises `-gluescript` and
`-gluescriptFile`; the extracted Classic GlueXML uses
`AccountLogin.UI.AccountEditBox` and `.PasswordEditBox`. This is evidence for a
candidate, **not proof that the release client's flags execute scripts**.

The candidate fills those fields once when visible and stops watching after 30s.
It never submits authentication or changes game data. Native renderers use
three-digit decimal UTF-8 escapes so quotes, backslashes and Unicode remain data.
The operator accepts the simpler startup-argument approach: escaped credentials
would still be recoverable from the private game's process arguments while it
runs. Escaping is not encryption. Do not claim they stay exclusively in Keychain
or Credential Manager if this path is adopted.

First use only fictional data, verify the displayed account and exact masked
password length, and do not submit a login. If the native flags are unavailable,
keep them disconnected; do not disable GlueXML integrity, signature, TLS or
certificate checks to enable them. Real-account acceptance and a fresh launch
from a saved entry follow only after the input path is proven.

## Validation checkpoint

`bash macos/Tests/run-login.sh` exercises actual Keychain create/read/update/delete,
realm separation, invalid input rejection, exact Unicode/punctuation and Lua
escaping. It disables interaction only in its own test process. The corresponding
Windows test exercises the real Credential Manager and is included in
`windows/test.cmd` and the Windows native-check workflow.

Current result: native Keychain checks pass and both Mac architectures compile
(both actual Mach-O minimum versions are macOS 12.0). The existing smoke suite
stopped at its running-game exclusion while the operator's game remained open;
it has not been accepted as a passed regression run for this branch.
The [Windows native CI run](https://github.com/MShkolenko/algalon-launcher/actions/runs/40519196006)
on source `bde6e3c36669b4744073018a12c8d4b835068caa` passed actual CredMan CRUD,
host/updater tests and both Algalon/example builds. This is a hosted Windows
runner result, not an interactive game-login test on the operator's Windows PC.
Native credential dialogs, actual release-client script acceptance, saved-entry
login and update-to-new-binary Keychain access are pending.
The working installed launcher/release assets are unchanged.
