# RFD0011 - Axo: menu-bar residency and first-launch setup

- Feature Name: `axo-menu-bar-residency-and-first-launch-setup`
- Status: Accepted
- Start Date: 2026-10-11
- Updated: 2026-10-11
- Document Type: Proposal

## Summary

Make Axo one menu-bar-resident Mac application whose workbench is an optional window, alongside the separate headless Axod LaunchAgent. First opening presents guided installation/service setup rather than an empty session catalog. Setup explains the ownership model, guides installation into a stable Applications location, requests background-service enablement explicitly, handles macOS approval, verifies the real daemon connection, and offers independently opt-in menu-bar startup at login. Closing a window hides presentation; quitting Axo saves drafts and removes the frontend without stopping Axod. This decision is accepted by the user's request to document and implement the agreed product model; it does not assert that installed-service or terminal-recovery acceptance has passed.

## Motivation

The current first-opening window can display “No sessions yet” alongside “Validating Axo's private daemon state.” No authoritative catalog has been read, so the headline misrepresents missing service connectivity as empty user data. Users must discover a separate Background Service window and understand macOS registration before the workbench is useful.

Axo's value includes work continuing without a visible window. A resident menu-bar entry gives users a stable way to reopen the workbench and inspect setup without pretending that the GUI process is the daemon. Two separately installed Mac applications would make quitting, signing, updating, preferences, and onboarding harder to understand.

The source baseline is `c99896d`. Relevant boundaries are:

- [`AxodWorkbenchApp.swift`](../../apple/AxoMacAxod/AxodWorkbenchApp.swift): AppKit delegate, singleton retained workbench window, menus, hide-on-close, draft-safe quit.
- [`AxodWorkbenchView.swift`](../../apple/AxoMacAxod/AxodWorkbenchView.swift): sidebar/detail and the misleading empty-state heading during disconnected startup.
- [`AxodServiceLifecycle.swift`](../../apple/AxoMacAxod/AxodServiceLifecycle.swift): application-scoped registration/readiness observations and explicit setup.
- [`AxodWorkbenchCoordinator.swift`](../../apple/AxoMacAxod/AxodWorkbenchCoordinator.swift): bounded read-only connection, authoritative catalogs, empty-startup intent, selection, and presentation resources.
- [`build-mac.sh`](../../scripts/build-mac.sh): atomic development-bundle packaging. Packaging is not installation or service registration.

The real current-profile service remains unproven: launchd has reported `copy_bundle_path` failures before executing Axod. Manually unloading/disabling the launchd label does not unregister the ServiceManagement background item. Guided setup must expose these conditions rather than silently repair or directly launch a helper.

## Goals

- One visible application identity and one persistent menu-bar control surface while Axo is running.
- An understandable first-opening path to installed, approved, responding background service.
- No empty-catalog claim before authoritative catalog reads.
- Separate GUI residency, frontend-at-login, daemon supervision, and runtime ownership.
- Preserve native workbench composition, selection, terminal resources, drafts, histories, and original operation records.
- Keep denial, incomplete setup, missing installation, and failed readiness actionable.

## Non-goals

- Two Mac app bundles, a GUI inside Axod, or another supervisor.
- An app that cannot be quit or that automatically resurrects after explicit Quit.
- Silent login opt-in, OS approval bypass, global background-item reset, or automatic service repair.
- Changing Pi, its canonical history, daemon RPC, device/cloud deployment, or terminal recovery.
- Automated replacement/moving of a running installation, administrator installation, notarization, or self-updating in this iteration.
- New independent workbench windows or concurrent viewport transfer.

## Guide-level explanation

### Mental model

**Axo is the resident control surface; Axod is the execution host.**

```text
Axo.app — one frontend process
  menu-bar entry
    Open Axo → setup or retained workbench window
    Settings
    Background Service
    Quit Axo → save drafts, remove frontend; leave Axod alone

macOS launchd → Axod → owned Pi and shell executions
```

The menu-bar item remains present when all Axo windows are hidden. The workbench may use a Dock presence while visible; hiding the last application window returns to accessory/menu-bar presentation. Showing, hiding, or activating a window never launches or stops work. Explicit Quit remains available and is subject to the existing draft-save barrier.

### First opening

1. Explain that Axo lives in the menu bar and Axod runs independently.
2. If the bundle is not in `/Applications` or the user's `~/Applications`, show installation guidance. The initial implementation reveals the current app and opens the user's Applications folder in Finder; the user quits, moves the app, and reopens it there. No hidden copy, replacement, deletion, or duplicate app launch occurs.
3. Offer **Enable Background Service** with an explicit explanation/confirmation. If already registered, check its actual availability rather than unregistering it.
4. When macOS requires approval, link to Login Items & Extensions. Returning to Axo only observes status; **Check Service** performs bounded read-only connection attempts.
5. A responding endpoint, validated epoch and negotiation, and successful catalog loading establish usable local connection. “Enabled” alone is insufficient. Failure remains in setup with the actual error and recovery links.
6. Offer **Keep Axo in the menu bar at login** independently. Preserve an existing choice unless the user explicitly changes it. Pending frontend login approval need not block an otherwise usable workbench.
7. **Open Axo** finishes setup and presents the workbench. The original authoritative-empty app-start intent may create its first session; an existing catalog, pending command, or unavailable draft store prevents automatic empty startup as before.

The setup-completion preference is a presentation hint, not registration or execution authority. Subsequent launches revalidate installation and connection before restoring the workbench. Once the workbench has been entered in this process, connection loss uses its recovery UI rather than repeatedly replacing an active viewport with onboarding.

### Close, reopen, and quit

Closing the primary window orders it out without disposing its retained surfaces. The menu-bar **Open Axo** item restores that same window, selection, and viewport. It does not request another create-if-empty operation or connect merely because a window is shown.

**Quit Axo** commits the field editor and waits for the draft persistence barrier. Failure refuses quit and reveals the window with an explanation. Successful quit removes the status item but does not unregister or terminate Axod. Starting again from Finder or a separately approved login item revalidates the service; it does not replay unknown work.

## Reference-level explanation

### Architecture and boundaries

- The AppKit application delegate owns one `NSStatusItem`, its menu, activation policy, and the retained primary window. No SwiftUI-scene migration is required.
- A small pure setup policy classifies installation and service/connection facts into a closed set of presentation stages. It owns no daemon or catalog.
- A dedicated hosted setup view emits explicit actions to existing owners. It does not register services in `onAppear`, start Pi, or perform filesystem installation.
- The application root chooses setup versus workbench. The native outline and terminal tree remain unchanged inside the workbench.
- The application-scoped service lifecycle remains the only normal service-operation owner. Connection attempts are read-only; the development operator-maintenance modes remain separate explicit tools.
- The status menu observes readiness and provides Open Axo, Settings, Background Service, and explicit Quit. It does not offer an inadequately specified “force restart” or historical-process cleanup action.

### Setup states

| Stage | Meaning / available action |
| --- | --- |
| Installation | Current bundle is outside a stable Applications location; explain and reveal in Finder. |
| Enable service | No service is registered; offer explicit enablement. |
| Approval | Background item requires user approval; open System Settings and check again. |
| Checking | A current read-only connection attempt is running; no success claim or duplicate setup dispatch. |
| Unavailable | Registration is missing/broken/unknown or connection failed; show actual error and supported recovery actions. |
| Ready | Negotiated connection/catalogs are available; independently choose frontend-at-login and open workbench. |

A transient initial unknown registration may render a checking state. After observation, unknown/unavailable registration is an error, not an infinite spinner. Registration denial and user disable are never mapped to empty sessions. A known manually disabled launchd job may still appear registered through ServiceManagement; actual readiness must therefore remain a separate gate.

### Installation boundary

The initial implementation deliberately uses native Finder guidance rather than a custom self-installer. Supported stable locations are the system and current user's Applications trees; translocated or development staging paths do not satisfy installation. Resolve filesystem aliases when checking the actual bundle location.

Moving an app with live accepted work is not authorization to replace the helper. Existing owner/operation fences from [RFD0010](RFD0010-macos-daemon-lifecycle-and-recovery.md) remain in force. Original installation and service records are not discarded to make setup appear fresh. A future automatic installer must separately specify atomic signed-bundle copy, existing-destination collision, source/destination identity, privilege prompts, handoff, and rollback before being introduced.

### Residency and activation

Retain the status item for the frontend process lifetime. Use a template symbol with accessible label and tooltip; native menu items retain standard keyboard/accessibility behavior. Refresh its informational status when the menu opens, without registration or work side effects.

A visible primary/settings/service window uses regular activation and native focus. Hiding the last Axo window changes to accessory policy; **Open Axo** restores regular policy before bringing the existing window forward. Inspect actual application windows so closing the workbench does not hide a still-open Settings window from normal desktop navigation. App termination after the last window closes is explicitly disabled.

Login launches should be identified through the macOS login-item launch event and remain menu-bar-only until the user opens Axo. Finder/manual launches show setup or workbench. Do not guess login launch from an arbitrary private environment flag. An unrecognized launch is a normal explicit launch, not proof of login activation.

### Completion, persistence, and concurrency

A versioned setup-completion hint uses the injected frontend preferences; disposable tests never write normal preferences. Unknown future preference values are not silently downgraded. Registration, actual endpoint/epoch, private draft readiness, and authoritative catalogs are revalidated regardless of the hint.

Before awaiting a login-setting change or finishing setup, capture the current source/connection identity. Revalidate afterward; a stale ready screen cannot complete setup against a different daemon. Present failures from the shared lifecycle without clearing original tickets or changing canonical bytes. Prevent duplicate Finish actions while an operation is pending.

Service enablement retains the owner-absence fence and existing platform-error semantics. An unknown setup outcome does not justify repeated unregister/register. Do not clear the existing failure latch simply on opening the view. OS approval requires user action, and a reconnect/check action only observes and negotiates.

### Invariants

- One app bundle and one frontend-owned status item; Axod has no AppKit UI.
- Window close/reopen and menu construction never admit, clone, stop, repair, or upgrade executions.
- Registration eligibility, responding daemon, loaded catalog, and restored viewport are different facts.
- Setup cannot display “No sessions yet” without authoritative reads.
- Setup completion is not a substitute for readiness or service-operation authority.
- Login startup remains separate and explicit; no unrelated service or global database is modified.
- Closing hides the retained window; real quit retains the draft barrier and leaves Axod alone.
- Current manual disablement and original uncertain operations survive packaging and presentation changes.

### Compatibility and migration

No daemon/protocol/history schema changes are required. Existing users retain IDs, paths, credentials, drafts, receipts, selection, layouts, and login preference. Absence of the new hint presents setup once; it does not reset an existing profile. Healthy existing users may finish without registering another helper. Explicitly disabled/broken service stays in setup until actual supported readiness is available.

This decision supersedes RFD0004's earlier choice not to add a menu-bar surface. It retains native AppKit composition and the headless ownership/safety contracts of RFD0007 and RFD0010. RFD0010's current-profile startup and separate VT recovery gates remain unresolved; this document does not claim they are solved by onboarding.

### Security and privacy

Use supported AppKit and ServiceManagement APIs. Respect approval, signing, Accessibility, and sandbox denials. No password collection, automatic administrator commands, shell installers, global BTM reset, ad-hoc installation variants, or direct production daemon fallback.

Display only bounded lifecycle/registration facts in the menu. No prompts, terminal text, credentials, private config, argv, or sensitive directory contents enter status tooltips/logs. Finder reveal acts on the app bundle, not private state or project paths.

### Validation and acceptance

- Pure tests cover installation paths, all registration/connection combinations, unknown states, stale readiness, completion hints, and login preference preservation.
- Native AppKit tests exercise one status item, menu actions, hide/reopen of the same window, activation, retained identities, and explicit quit versus window close without service calls.
- Existing protocol/native/workbench tests continue to prove no duplicate work or altered history.
- Actual packaged first-launch UI must show setup rather than false-empty sidebar. Testing uses owned fixtures and injected platform observations; it does not silently approve or register the user's service.
- Real installed Applications-path setup requires a separately consented account/VM or operator flow, including approval/disable, login-only residency, moved bundle, failed startup, and healthy reopen.
- UI denial remains a blocked gate. Same-bundle frontend guards remain in force; no silent close to run tests.
- Repackage the exact committed source and verify strict signatures. Packaging does not authorize activation of a disabled service.

## Drawbacks

- Menu-bar residency retains frontend memory and cached terminal resources when the window is hidden; existing cache budgets still apply.
- Activation/Dock policy and login-launch detection need real macOS acceptance beyond component checks.
- Manual Finder installation is less seamless than a robust self-installer, but avoids a speculative destructive upgrade path.
- Setup exposes real ServiceManagement failures and can prevent entering the workbench when macOS cannot launch the host.
- A presentation hint and first-launch gate add another state boundary; they must not become daemon truth.

## Rationale and alternatives

### One resident frontend plus a headless host

Selected because it matches the accepted ownership model and offers one discoverable entry point. AppKit's status item composes naturally with the existing delegate/window; a second executable app is unnecessary.

### Just open Background Service settings on error

Simpler, but does not explain installation, residency, or the independent login choice. The initial empty-looking workbench still teaches the wrong mental model.

### Two GUI app bundles

A “daemon app” with a menu bar and a separate workbench app introduces duplicate application identities, signing, updates, settings, and IPC. The menu bar is client UI, not evidence of daemon ownership. Reject it unless a future distribution requirement establishes a real boundary.

### Menu-bar GUI owns executions

Hiding rather than quitting a frontend does not make it a suitable host. It violates the selected launchd/Axod ownership model and still interrupts work on GUI crash or explicit quit.

### Automatic self-install/repair

Potentially smoother, but replacement of a signed running bundle and service has its own filesystem/platform ambiguity. Prefer bounded manual installation and explicit service consent first. Do not silently restart a host to finish an onboarding wizard.

### Do nothing

Retain a hidden workbench with no menu-bar entry and display loading as no sessions. Users continue confusing window, registration, and execution lifetimes and resorting to reset/restart as setup.

## Prior art

- [RFD0010](RFD0010-macos-daemon-lifecycle-and-recovery.md) defines the single supervisor, separate observations, and original-operation contracts.
- [RFD0004](RFD0004-axo-macos-application-architecture.md) defines presentation/resource boundaries; this decision adds a concrete resident control surface without a framework rewrite.
- Apple's [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) provides an application-owned menu-bar item, not daemon supervision.
- Apple's [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) separates main-app login startup from a bundled LaunchAgent and macOS approval.

## Unresolved questions

### Before acceptance

The user accepted one resident app identity, a headless host, optional workbench window, guided setup, and independent login startup. No two-bundle or new execution-owner decision remains open.

### During implementation

- Exact login-item Apple Event delivery behavior and hidden-window activation on the supported macOS version.
- OS background-item bundle resolution and stable-installation behavior for the development ad-hoc-signed artifact.
- Accessibility and UI-test authorization for packaged activation/menu behavior.

### Out of scope

Automatic installer/updater, global background-item recovery, terminal snapshots, independently surviving PTY workers, and multiple concurrent workbench viewports.

## Future possibilities

A separately specified signed installer can automate the Finder step and a separately authorized update flow can replace an idle helper. The status menu may later route attention notifications to an existing session/window, without becoming another execution controller or implying work replay.
