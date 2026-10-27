# Native Mac remembered-login acceptance — 2026-10-27

Candidate: Algalon Launcher1.2.0(8), native arm64 execution on macOS27.0.1.
Client: WoW Forever1.60.1.70630, isolated private release application.
Times below are Moscow time. No account values, credentials, session material,
raw logs, private endpoints, personal paths or machine identifiers are included.

## Confirmed behavior

- Native AppKit form offers account, secure password, Remember, Play, Manual Login,
  Cancel and exact-record removal. Play fills the game; Log In remains explicit.
- Disposable native Keychain tests cover CRUD/update/delete, invalid records,
  exact Unicode/punctuation and realm separation. The real saved entry was read
  on repeated unchanged-binary launches without another Keychain prompt.
- A different fictional account was placed in the account field, with a separate
  masked password. No login was submitted for this control. The intended saved
  account was restored before real acceptance.
-21:30:45–21:30:51: recognized login layout, verified account replacement,
  nonsecret password-focus control and final field filling all passed.
-21:32:06.438: account logon completed ERROR_OK. The password came from Keychain;
  no clipboard or script arguments were used.
-21:32:08: one complete validated region-key table installation was reported.
-21:32:08.855: realm authentication returned ERROR_OK; character list followed.
-21:32:37.389: world and spells loaded100%, loading screen disabled. The world
  was independently observed through the game UI.
-21:34:25: launcher observed normal game exit and completed without an error popup.

The temporary fictional account was removed from the saved record by restoring
its intended account through the launcher form. No supplied password was copied
into test source, configuration, arguments, environment, logs or build inputs.

## Separate unsuccessful attempt

At21:23:45, account/HTTP/SRP authentication succeeded, realm join returned
ERROR_OK21:23:46.505 and the realm connected21:23:46.523. The realm closed
21:23:48.522 before world entry. The launcher reported one validated table write
at21:23:50 after its full scan returned. This timestamp does not determine the
exact write instant. A server correlation was requested in coordination issue1,
comment6450359767. The following saved-entry run succeeded. The first failure's
cause remains open; neither a bad password nor a scanner timing race is proved.

## Input repair and controls

The earlier PID-posted mouse events left WoW's previous hit target active. Native
WindowServer mouse movement/down/up, frame-separated events and topmost exact
window checks repair that route. Keyboard remains PID-targeted. Correctly
remembered account text is retained, otherwise a nonsecret account marker and
actual account must both pass readback. A nonsecret password probe and final
unchanged-account readback guard secret input. Window-local capture coordinates
are converted to screen coordinates including offsets; invalid geometry refuses
input. Images and arbitrary OCR text remain transient and local.

Stock command-line controls, including a separate quoted relative
`-gluescriptFile` filename, were rejected by this client's command-line parser.
They did not execute Lua. Those controls used fictional account text only and
never attempted login. Unused script renderers/template were removed.

An independent read-only Claude Opus5.5 max-effort review informed the focus,
geometry and input timing controls. Its chronology inference about the previous
Tab-based run was not adopted: that successful earlier run predated Tab.

## Signing and remaining limits

The local candidate uses an existing Apple Development signing identity and a
stable designated requirement. Subsequent changed builds retained the approved
input/capture rights and saved-entry access. No private key was generated or
exported, and no ACL/trust broadening was used. The personal-signed local app is
not distributed. The separately packaged universal candidate is ad-hoc signed;
it is a prerelease for owner review, not a notarized general-distribution release.
Actual game acceptance used the local Development-signed arm64 build. The
ad-hoc universal package passed archive/signature/build controls, but its actual
permission/Keychain prompts and Intel execution were not interactively accepted.
Changed ad-hoc binaries can require those approvals again after each update.
The owner still needs stable Developer ID signing/notarization for reliable
Keychain/TCC identity across public binary updates. Production feed/manifests and
the owner's offline signing key were not changed.

All53 official application baseline entries retained identical hashes, sizes,
modes and modification times. Its existing unsigned `icudt78l.dat` verification
defect remains; it was not repaired or re-signed. Installed and distribution
launcher bundles pass deep/strict signature checks. SIP, TLS/name verification
and existing system trust were preserved. The current native feature does not change the key scanner.
Before authentication one read-only process sample showed roughly85% of one CPU
and122MiB RSS for the launcher, largely its inherited full memory scanner. This
is a spot sample, not a sustained profile or a claimed performance improvement.
Idle scanner optimization remains separate work and must preserve full-table
validation and recovery behavior.

Intel hardware, macOS12/13 manual execution, additional display layouts,
clean-Mac Gatekeeper/notarization acceptance and interactive Windows input have
not been exercised. Automatic filling is gated atmacOS14; the base launcher
continues to targetmacOS12 with manual login. Windows CredMan/UI adapters are
prepared, but not connected to game input. The original updater/private-copy
acceptance remains separate from this saved-login acceptance. Final native smoke
checks pass88 markers, updater checks pass75 plus the two actual final ZIP
acceptance/extraction controls. Both universal slices build and sign successfully.
The graph map is refreshed; it has15 unsupported-file gaps and two partial AST
extractions (AutomaticLogin.swift and the C header), so it supplements source
review rather than proving complete semantic coverage.
