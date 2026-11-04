# Native input repair and release70707 acceptance

Candidate1.2.2(10), macOS27.2, release client1.60.1.70707 arm64. Reconciled
main6a1a93c; the complete Windows tree remains byte-exact to that main. The minimum
is macOS12 for manual login and macOS14 for automatic filling.

## Confirmed installed result

The installed launcher read the existing Keychain record without another approval
prompt and filled the separate account/password fields without the clipboard.
Automatic filling completed at19:23:38MSK on2026-11-01. The ordinary Log In and
Enter World actions were then driven by an isolated native acceptance control;
the distributed launcher still leaves Log In explicit. No password was supplied to
the control, arguments, environment, source, files or logs.

- 19:27:55.145MSK: SRP completed with ERROR_OK.
- 19:27:55.313MSK: account authentication event completed with ERROR_OK.
- 19:27:57MSK: one validated region-key store was patched; one installation total.
- 19:27:59.046MSK: realm authentication completed with ERROR_OK.
- 19:27:59MSK: character-list success events; existing character visually present.
- 19:28MSK: existing character entered the world; the loaded world, character,
  terrain, NPCs and normal HUD were visually confirmed. No new character was made.
- 19:32:05MSK: Exit Game completed; independent native process-exit observations
  confirm status0 for both game and launcher. No monitoring failure was recorded.

The earlier fictional-only control also filled four masked characters in the correct
field. Its first attempt failed closed with targetChanged before input. That earlier
control was later forcibly stopped after the UI driver could not close it, producing
an expected abnormal-exit alert. This is separate from the successful installed
session and must not be called a spontaneous crash or a clean-exit test.

## Root causes and repair

The1.2.1 guard refused Secure Input before password delivery. A same-process A/B
control established that PID-targeted CoreGraphics Unicode delivery still works
on70707. Removing the refusal alone would not establish interruption cancellation:
external keyboard taps are not reliably observable under Secure Input.

The existing private native module now filters AppKit input locally. A validated,
nonce-bound inherited anonymous socket carries one permit and acknowledgement at
a time, without text. Foreign input, native key-window/geometry changes, expiry
or EOF close the input path. Queued own events remain filtered after abort, with
one paired empty release allowed. A short-lived mouse-only tap covers outside-window
interruption. Successful filling removes the filter. Secure Input is never disabled.

The visual password band previously clipped glyphs and included frame pixels. Its
corrected interior preserves whole glyphs. Independent measured-pixel controls fail
with the old geometry and pass with the repair. Positive W/i mask and erasure proof,
account readback, actual key/click acknowledgements and Secure Input are required
before password entry. Initial activation uses only a recognized, exact owned window.
No clipboard, Lua, internal game-text hook or automatic credential retry is used.

## Current server contract

The owner confirms70707-only support. Portal TLS21843 and LoginREST HTTPS22517 are
updated through the Mac profile generator. Selected-address transport checks refuse
old1119/1120. The HTTPS proxy exception applies only to the exact realm host on22517;
old8082 uses the native proxy result. Existing1120 configuration migrates while
retaining graphics, user settings and both locales. World23964 remains server-announced.
Site24713 and CRL CDP24780 are owner configuration; this launcher does not override
system trust, CRL policy, system proxies or routes. Native Apple Security checks
verified hostname and certificate chain on both new TLS endpoints before credentials.

## Validation and independent review

- 35 actual multi-process AppKit input cases pass, with native exit0 and matching
  current source and fixture-binary SHA256. They cover production click fallback,
  exact-window negatives, foreign input, native-only and tap-only interruption,
  paired/duplicate/orphan releases, tags/types/replay, stalls, expiry, EOF and real
  intermediary SIGKILL. Every run uses a fresh report directory.
- Independent isolated mutations fail their intended runtime assertions: expiry
  removal delivers a forbidden key; removing both EOF detectors does the same;
  removing the current-permit fallback tag drops the required SIGKILL mouse release.
  No mutant is installed in the product.
- Fresh forged events replace a faulty test that tried changing an already-assigned
  CGEvent tag. This OS ignored the second assignment; the product tags fresh events once.
- Native receiver17 and production Swift receiver11 protocol/fragment/invalid-ack/
  timeout controls pass. Disposable Keychain, Unicode, realm separation, layout,
  mask/erasure and native monitor controls including40 exits pass.
- Both universal profiles and strict signatures pass.91 smoke and77 updater PASS
  markers include the actual final archive. An initial overlapping test run changed
  Generated inputs during compilation; the serial rerun is the acceptance result.
- Opus5.5, native max effort, independently reviewed the implementation twice and
  then this final product/fixture source. It found no P0/P1 or secret/targeting leak.
  Earlier descriptor/release/permit fixes and four final fixture requests are applied;
  all35 current runtime checks pass. Source review does not replace game acceptance.

The original official application still matches all78 captured root/file/link/
directory records after the installed run, including signature files; SIP is enabled.
Strict bundle verification refuses its unchanged unsigned vendor icudt78l.dat
subcomponent. This is not a successful strict official-bundle check; no official
repair or re-sign was attempted. No system trust, protection setting, official cache
or official signature was changed.

## Limits

Public artifacts use the owner's chosen ad-hoc signature. The accepted local install
uses the existing Development identity; that personally signed app/key is not
redistributed. Ad-hoc updates can require renewed Keychain/TCC approval. Developer ID,
notarization, clean-Mac installation, Intel hardware and older OS runtime are untested.
Owner alone signs/promotes the production update manifest. Historical1.0.4-to1.1.1
feed activation is confirmed; current1.2.2 production-feed activation is pending.

The game can change widget focus programmatically between independent checks;
CoreGraphics targets a process rather than a game widget. Parent death before any
mouse-up was posted also remains qualified. The current controls cover the measured
paths, not every physical keyboard or third-party event source.

A15-second world-loaded observation measured about35% of one CPU core and89MiB RSS
for the launcher. This is a short observation, not a sustained benchmark or a low-idle
claim. The unchanged region-key scanner still sweeps every3seconds after installation;
its resource cost needs a separate measured optimization that preserves detection
and validated-write safeguards. The old sporadic monitoring warning is not claimed
universally eliminated; this current session and the bounded exit controls pass.
