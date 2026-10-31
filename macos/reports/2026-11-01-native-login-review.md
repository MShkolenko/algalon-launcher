# Mac native-login review continuation

Status: work in progress. This is not an accepted password-autofill release.
Candidate:1.2.1(9). Reconciled main:53698e4. Client:1.60.1.70658 release arm64.
Tests ran on macOS27.2 / Apple Swift6.4.2; declared minimum12, autofill14.

## Confirmed current behavior

- A small windowed private client launches. Its isolated configuration/cache and
  the original saved Keychain entry are retained. No new real-account login was
  submitted during this continuation.
- ScreenCaptureKit supplied the window's global screen rectangle. The previous
  mapping added the window origin twice. The shared conversion now uses it once,
  requires all four capture/window edges to agree within one point, and validates
  coordinates. The actual fictional marker and account readback pass in WoW.
- Focusing the password field makes the game own macOS Secure Input. The current
  guard refuses before the W/i password proof and password delivery. This refusal
  is preserved; it must not be described as successful password autofill.
- A background-game alternative was not established: native activation requests
  returned success but did not actually make the requested other application
  frontmost. Secure Input remained enabled. Those are failed activation controls,
  not evidence that the proposed background delivery works or cannot ever work.
- Isolated fictional diagnostics found an object advertising NSTextInputClient.
  Direct insertText:replacementRange: did not change the field. Posting a native
  NSEvent pair reached a temporary local monitor but also did not change the field.
  No cooperative helper, new IPC or game-internal field hook was adopted into the
  product. These experiments never read saved credentials or submitted Log In.
- One normal Quit produced the old generic monitoring error. Its original journal
  lacks the failure reason, so that event's exact cause remains unproven. The source
  did conflate process disappearance before Foundation's exit notification with a
  live identity mismatch. It now distinguishes ESRCH/exit, logs live failure reasons,
  and preserves abnormal-exit errors and live identity/write failure handling.
  Subsequent real normal quits completed without that warning. The fix narrows
  that race; it does not prove that every Mach/BSD teardown overlap is quiet.

## Comparison with the accepted October27 implementation

The accepted1.2.0 source6664218 used PID-targeted native CGEvent Unicode delivery.
It had no IsSecureEventInputEnabled refusal. Its actual70630 saved-entry account,
realm and world acceptance is recorded in2026-10-27-native-login.md.

The1.2.1 guard adds that refusal both at initialization and before input. The
current70658 secureInput result is raised by this launcher policy before password
text is posted. It does not establish that macOS rejects the accepted CGEvent
route. The unsuccessful insertText/NSEvent experiments used different delivery
APIs and do not refute the historical method. External keyboard-tap observability
under Secure Input remains a separate cancellation constraint; deleting the guard
would not establish that requirement.

A fictional-only comparison of the historical CGEvent route is prepared, with the
window-coordinate correction retained. It has not run on70658: an official WoW
session is active, and the diagnostic launcher correctly refused a simultaneous
private client using the shared game data. The official session was left running.
No saved credential was read and no login was submitted for this comparison.

The accepted local1.2.0 was Development-signed; installed1.2.1 is ad-hoc signed.
Both pass strict verification. The different signing identity explains renewed
Keychain authorization and is separate from text delivery. The owner's public
ad-hoc distribution policy remains unchanged. No protected authorization dialog
was automated and no saved-entry ACL was changed.

## Independent validation and limits

The native two-process input fixture passed20 scenarios on the preceding reviewed
input snapshot: own delivery, five foreign Tabs and clicks, covering/non-overlapping
same-process window switches, stalls, Secure Input refusal, missing delivery,
mid-string interruption, queued-event drain and paired mouse release. The final
app-element AX timeout was subsequently tightened to50ms. These AppKit fixture
results do not establish WoW password-field compatibility. The earlier artificial
Secure Input packet-bypass failure remains a separate negative, not a passed test.

Current disposable Keychain/layout tests pass, including screen offsets, negative
origins, fullscreen coordinates and malformed/out-of-window/nonfinite geometry.
Independent CoreText mask/clear/dead/erasure controls pass. Native monitor tests
pass good/malformed table cases while UI completion is suspended,40 normal child
exits and refusal of a live executable mismatch without killing it. The40-exit
stress also passed before the liveness change; it is not a deterministic reproduction
of the observed game warning.

The scoped Opus5.5 MAX-effort UI and exit-notification reviews were completed.
The follow-up Secure Input review identified the current platform boundary and
recommended the stricter coordinate/AX checks now applied. It did not verify a
working password-input route. A broader key-table review was declined and is not
claimed. The final delta review accepted the excerpts as qualified WIP without a correctness
blocker. Its recommendations for clearing errno, observable exit classification,
timer cleanup and independent edge-tolerance cases were applied. It did not review
the entire scanner or establish successful password filling.

Fresh checks:89 smoke PASS markers,77 updater PASS markers including the actual
candidate ZIP, real Keychain/layout and independent CoreText controls, and the
four native child-monitor controls all pass. Both profile bundles build as
arm64/x86_64 and pass strict all-architecture signature checks; ScreenCaptureKit
is weak-linked in both slices. The offset-coordinate regression exits1 on the
previous source and0 on the correction. Build details are in validation.json.

After the native controls, all53 baseline official application file/link hashes,
sizes, modes and modification times remained exact, and SIP remained enabled.
No system trust, server configuration or official-client change was made. Shared
CASC data retains its previously documented normal-write qualification.

## Performance qualification

An unconfirmed full-scan runtime snapshot was about78% of one CPU core and94MiB
resident memory. This is not a sustained benchmark or a low-idle acceptance result.
The current independent monitor's responsiveness and complete validation are retained;
performance and post-authentication timing still need current-client measurement.
All diagnostic game processes are closed after these controls.

## Remaining gates

- Obtain owner confirmation of current70658 realm support.
- Establish a supported, positively targeted and cancellable password-delivery
  route. Do not disable Secure Input or rely on blind external taps. A documented
  client/server login-ticket integration is another owner-coordination option.
- Run fresh saved-entry account/SRP, realm, one validated key installation,
  character/world and clean-exit acceptance on the resulting implementation.
- Obtain the owner's second source review before merge or production promotion.

Windows remains exactly the owner's main tree. Historical macOS70630 world
acceptance on October27 and signed1.1.1 feed activation remain valid historical
results; they do not establish acceptance of this candidate. No production manifest
key or feed promotion is performed by this continuation. Ad-hoc distribution and
its renewed OS approval prompts are the owner's explicit choice; clean-Mac,
Intel-hardware, older-OS and mixed-display runtime acceptance remain untested.
