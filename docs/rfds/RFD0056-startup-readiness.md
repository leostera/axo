# RFD0056 - Axo: startup readiness

- Feature Name: `startup-readiness`
- Status: Implemented (Axo 0.66 first pass)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-15
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md), [RFD0051](RFD0051-generated-axo-cli.md)

## Summary

Run a read-only readiness check at every normal app startup and present one compact setup checklist for this Mac, also available from Settings and the Axo menu. Check grants from the process that actually uses them: axod for computer use, Developer Tools, protected files and Automation; Axo.app for notifications. Explain each capability, offer explicit per-row fixes, and recheck on activation or request completion. Unknown, missing, unavailable and partially allowed are not granted. The checklist is not an authorization cache or a promise that arbitrary future tools will succeed.

## Motivation

Today axod requests Finder/System Events Automation at launch, the app offers Developer Tools separately, notification delivery can request notification permission, and the app has a separate first-launch CLI offer. Accessibility and screen-recording checks exist in the driver but have no coordinated setup UX. People can finish installation with a working terminal and later discover that computer use or notifications do not work. Independent startup prompts also obscure which executable needs the grant.

**User decision:** setup should check all the permissions Axo currently needs so the person can address them together before relying on it. Permission checks must remain honest about macOS limitations and must not alter privacy settings or restart sessions silently.

## Guide-level explanation

Axo checks this Mac during startup. A setup window groups:

- **Sessions and background operation:** the Axo and axod Login Items/service state.
- **Computer use:** axod Accessibility and input-control preflight, screen recording, supported driver and lock state.
- **Development and files:** axod Developer Tools and protected-file/Full Disk Access status.
- **App automation:** axod → Finder and axod → System Events, separately.
- **Notifications:** Axo.app authorization and actual alert/delivery settings, including quiet/disabled delivery.
- **Command line:** the existing stable CLI link as optional setup, respecting the installer's opt-out/handled-choice preference.

Each row names the owner and explains its purpose. The fix requests only that permission or opens the correct System Settings pane and reveals the axod helper when it must be added manually. Notifications are requested by Axo.app; computer/Automation requests run in axod. There is no “grant everything” button, automatic TCC modification, or fabricated success after opening Settings. Continue is always available for people using only some features.

For example, Accessibility may be enabled while screen recording is off. Sessions remain usable, but the computer-use group says it needs setup. After the person changes Settings, Axo checks the daemon again; if the OS still reports blocked, it explains that a daemon restart may be needed. Restart remains an explicit action with the existing warning that terminals restart. Unlocking and being allowed notifications do not defeat the screen lock or Focus.

A new profile sees Welcome → Setup → Connections → Ready. Connections checks the local daemon and account status on entry and every five seconds while visible; it runs no commands and alters no Sessions. An unlinked account offers the existing pairing Settings flow, but never starts linking automatically or blocks local use. Linked-but-offline, unlinked and unknown are distinct; older daemons without linking metadata remain unknown rather than being guessed unlinked. Leaving or closing the step retires outstanding UI results. This is not a provider/model or end-to-end computer-use test. The permission step prefers enough height for all nine rows, clamped to the primary usable frame; other steps use a shorter window. Smaller windows keep a rounded scroll viewport, an overflow hint and a named jump-to-unchecked summary. Profiles with existing Session-use preferences go straight to the repair checklist. A new profile sees the setup window once. Subsequent boots still run checks but do not repeatedly open it for the same acknowledged limitations. Recovered issues leave the acknowledged set, so a later revocation becomes a new issue. Store acknowledgements/presentation preferences only, never grants. The person can always reopen the checklist and recheck. Do not pile the old Developer Tools/CLI offers over this window.

## Reference-level explanation

### Process ownership and probes

- Add a read-only `axo.daemon.permissions` report containing the reporting PID, platform/support information and explicitly typed observations. Run blocking OS probes off the relay/socket executor. Expose its ordinary local CLI projection rather than a new backend.
- AX and screen-recording checks reuse the same live Cua probes as computer use. Screen access must use `CGPreflightScreenCaptureAccess`, never window-list/screenshot heuristics. Check `CGPreflightPostEventAccess` for actual keyboard/pointer posting as well. No captures, event taps, input, model warm-up, downloads or tool actions are performed to diagnose readiness.
- Developer Tools reuses the existing dynamically looked-up private TCC preflight. Protected-file access uses the analogous service only as a best-effort observation. Unavailable/unknown private API results stay unknown; do not read the TCC database or claim universal disk access.
- Automation uses `AEDeterminePermissionToAutomateTarget` with prompting disabled. Apple documents that its descriptor must identify an already-running app; `procNotFound` means not checked/not running, not denied or granted. Do not launch a target merely to inspect it. This report covers the two fixed startup targets, not permission for every installed app.
- Notifications use `UNUserNotificationCenter.notificationSettings()` in Axo.app. Authorization alone does not prove alerts are enabled; distinguish quiet or disabled delivery. Focus and actual notification delivery are outside the readiness guarantee.
- There is no blanket request for microphone, camera, location, contacts, critical alerts or arbitrary app integrations. This driver uses active per-process focus-notice taps, not a general keyboard-listening tool; do not infer a new mandatory Input Monitoring requirement from the presence of an event tap.

### Explicit repairs

Add an Axo.app-signature-only `axo.daemon.permissions.request` for a fixed enum of the two Automation targets. Accessibility, screen recording, Developer Tools and protected-file fixes open System Settings with a native floating, copy-only drag guide for the real axod executable; they do not request grants from the wrong GUI process. No arbitrary service, bundle ID, script or target process is accepted. Unsupported targets/platforms reject before effects. Serialize admitted requests and retain ownership through OS completion even when the caller loses its receipt. Never automatically retry a prompt; recheck observed state. The CLI may inspect but cannot request these grants by impersonating Axo.app.

Full Disk Access and Developer Tools require manual System Settings actions; opening those panes is not evidence of permission. Notification requests are explicit checklist actions; notification delivery paths should inspect existing authorization rather than launch another first-run prompt. Preserve the safety judge, human-approval ownership, protected input and locked-screen refusals independently of checklist state.

### Native state and lifecycle

Use a typed, injected readiness model and read-only startup probe, shared by the setup window and Settings. Check at startup, on activation and after a fix; bound the wait and display unavailable instead of hanging startup. In-flight checks have a generation; stale/late replies cannot overwrite newer observations. Invalidate daemon observations across service transitions. A failed/old-daemon response is never an all-ready report. One explicit repair can be in flight; closing a view must not abandon its admitted OS request or retry it.

The visual identity remains Axo’s: its own artwork/mascot, native appearance preference, leading-aligned content and conventional step labels/navigation. Hex is a reference for guided handoffs and state ownership, not a copied theme, typography, icons or screen layout. Success green uses a quieter, appearance-aware tone.

Test/fixture launches must not schedule startup windows, ask for privacy permission, register services or modify the person's preferences. The checker does not start/restart the daemon for testing. Existing daemon registration and confirmed upgrade paths remain the owners of that lifecycle.

### Compatibility and rollout

The new report/request methods are additive. Older daemons lack the report and must be shown as unavailable/update-needed, not fully ready. Update the advertised-method catalog, local schemas, Swift client and explicit CLI exclusions together. The next daemon build is required for the full report. No cloud/account permissions or Linux desktop redesign are included.

## Invariants and tests

- Checking has no permission prompts or computer-use side effects; requests require the signed app and a valid fixed target.
- Unknown/absent/unsupported/quiet-delivery observations never become fully granted; the reporter's PID is positive and the observation is live, not a persisted grant.
- No boot/read request launches an Automation target. Not-running and unsupported results remain visible.
- Only current-generation responses update the checklist; one repair owns its slot through receipt loss and OS completion.
- No daemon restart, privacy database edit, blanket grant or suppression of the independent computer-use gate is implicit.
- Unit/model tests cover incomplete probes, late results, recovery/revocation, skip/reopen and prompt serialization. Native fixtures render the actual checklist without launching the person's app. Isolated daemon tests cover the real report and protected-call refusal. Downloaded signed bundles must pass updater/package verification and fixture-client checks without replacing the running app or granting permissions on the person's Mac.

## Update review window

Manual Check for Updates always opens a dedicated review window, centered in the primary display’s usable area rather than the key window’s display. Checking, current, unavailable and failed states remain explicit. Current and offered semantic versions are visible; a daemon-build change warns that terminals restart and retains the existing confirmation. No manual check installs implicitly. A background refresh changing the candidate forces review again rather than substituting a different release under the install button.

Release notes come from CHANGELOG.md at the exact published Git commit, capped at 128 KiB for the file and 24 KiB/256 lines for the selected version section. They are advisory text, rendered without a web view, remote images or executable/deep-link content; only explicit HTTPS link navigation is allowed. Missing notes do not disable signature-verified installation. The immutable manifest and updater signature/metadata checks remain unchanged. Skip applies only to that build; Remind Me Later permits one banner after 24 hours, without lowering the existing notification high-water mark. Manual checks ignore both preferences.

The bounded logical model in `specs/setup/readiness.ts` covers fresh generations and owned requests, not OS accuracy/crashes/network faults. Its source ranges are not yet in the global lock; no locked-source proof is claimed. Native fixture screenshots cover light/dark onboarding and the update window; real daemon conformance covers live report shape and protected-call refusal without opening OS prompts.

## Drawbacks and alternatives

- A complete checklist cannot prove every future tool succeeds. Per-app Automation, protected content, screen lock, Focus and future revocations remain runtime concerns. Report capability-specific readiness instead of “everything will work.”
- Private TCC probes may stop working on a macOS update. Unknown plus a Settings action is preferable to an undocumented database read, a misleading green check or an invasive file-access test.
- Keeping independent launch prompts is simpler locally but leaves repeated and inconsistent setup. A blocking wizard that refuses terminal use until every optional grant is enabled would coerce unnecessary access. Automatically exercising screenshots, keystrokes or Apple Events would introduce privacy effects just to inspect readiness.

## Unresolved questions

- Implementation details: native window placement and the exact OS wording for settings links; handle failures without attributing a grant to the wrong executable.
- Out of scope: permissions for every third-party app, remote devices/phone, automatic screen unlocking, cloud sign-in, inference model installation and automatic daemon restart.
