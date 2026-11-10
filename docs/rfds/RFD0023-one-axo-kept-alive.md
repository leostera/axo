# RFD0023 - Axo: One Axo, kept alive

- Feature Name: `axo-one-axo-kept-alive`
- Status: Implemented (2026-11-01; the menu-bar upgrade was added later; two contributor-document follow-ups under Rollout are still open)
- Author: leostera
- Start Date: 2026-11-01
- Updated: 2026-11-10 (reconciled with the code)
- Document Type: Proposal
- Related: [RFD0019](RFD0019-planned-restarts.md)

## Summary

I propose that exactly one Axo.app runs on a Mac, that launchd keeps it running, and that opening another copy of Axo is how it is upgraded.

Five changes make that happen:

- **Axo has its own LaunchAgent.** `dev.leostera.axo.app` ships inside the bundle next to axod's and is registered with `SMAppService`. launchd starts Axo at login and again after a crash or a kill, but not after Quit Axo (`KeepAlive = { SuccessfulExit = false }`).
- **The Axo you open hands over.** Before SwiftUI starts, an Axo that launchd did not start looks for other Axos. If the same build is running, it brings that one forward and exits. If another build is running, it asks, stops it, registers its own bundle's agent, waits for launchd's Axo and exits. If nothing is running, it starts launchd's Axo and exits. The Axo you use is always one that launchd brings back.
- **Quitting is deliberate.** Quit Axo, in the menu bar and the app menu, quits for good. ⌘Q only closes Axo's windows. Logging out, restarting and shutting down still quit.
- **An Axo running an old build offers the new one.** Opening `dist/Axo.app` after an install over the running Axo only brings the running one forward, because macOS takes it for the app already running. That Axo notices that the bundle on disk has a newer build and offers to restart into it.
- **axod is registered again when launchd cannot run it.** Axo records the helper's signing identity with the registered definition. It also reads launchd's state before waiting for axod. A changed identity, or a job that is loaded but failing to start, makes Axo register axod again instead of waiting 30 seconds and giving up.

## Motivation

On 2026-11-01, Axo could not be started for most of an evening. The sequence:

- **17:36.** At the person's request, an agent wrote `~/Library/LaunchAgents/dev.leostera.axo.app.plist` by hand: `KeepAlive = true`, an absolute path to `dist/Axo.app/Contents/MacOS/Axo`, `--background`. Nothing in the repository knew about it.
- **18:50.** An uncommitted edit to `bazel/apple/sign_mac_app.sh` signed axod as `dev.leostera.axo.axod` instead of `axod`, to match its label.
- **18:51.** A build installed a new `dist/Axo.app`. The running Axo saw a new axod build and restarted axod with `launchctl kickstart -k`. The kernel refused the new helper: `AMFI: Launch Constraint Violation (enforcing) … Contents/Helpers/axod`, and launchd exited the spawn with `OS_REASON_CODESIGNING`. Background Task Management had approved the agent for a helper signed as `axod`, and a helper signed as anything else is refused until the agent is registered again. launchd hid this behind `last exit code = 78: EX_CONFIG` and `No such process: Contents/Helpers/axod`. Axo showed "Couldn't Load Sessions — Connection refused".
- Axo itself could not be replaced. Quit counted as an exit under `KeepAlive = true`, so launchd started Axo again at once. Opening the new `dist/Axo.app` brought the running Axo forward. A broken Axo kept coming back, and nothing offered to replace it.
- **19:18**, after the signature was fixed. axod still did not start: `copy_bundle_path(377B758D-…), error 0x6f - Invalid or missing Program/ProgramArguments`. launchd resolves `BundleProgram` through the bundle that registered the job, not through its path. Each install (`bazel/apple/install_app/main.swift`) swaps a new bundle into `dist/Axo.app` and moves the old one to `dist/.Axo.app.previous`. The next install deletes that copy. The job was registered from a bundle that no longer existed. Axo's recorded definition (bundle path and plist hash) was unchanged, so `DaemonController` kickstarted a job that could not spawn. It then waited for axod and reported a timeout.

Earlier that day (02:25), axod had also crash-looped. A missing Workspace directory failed startup, and launchd restarted it every 5 seconds. That bug is fixed separately (`cae6924`). It belongs to the same pattern: something launchd keeps alive breaks, and keeping it alive makes things worse unless something notices and replaces it.

The causes:

- Axo had no contract for being kept alive. The hand-made agent restarted it after a clean quit, ran whichever binary was at the path, and could not be upgraded.
- Nothing ensured that only one Axo runs, and an Axo started outside launchd would not come back after a crash.
- `DaemonController` judged whether axod's registration was current from what Axo recorded (bundle path and plist hash). launchd's own view was never consulted. A changed signature or a deleted bundle looked current.
- The only way out was by hand: `launchctl bootout`, deleting the plist, reading the kernel log.

## Goals

- At login, and after a crash or a kill, Axo and axod come back without the terminal window.
- Quit Axo stays quit until the next login, or until the person opens Axo.
- One Axo runs at a time, and it is the one launchd keeps alive.
- Opening a different build of Axo replaces the running one after asking. Opening the same one shows it.
- Installing a new `dist/Axo.app` and opening it reaches the new build, even though macOS brings the running Axo forward.
- When launchd cannot run axod or Axo, Axo registers it again, and says what failed if that doesn't work.
- No step needs a terminal.

## Non-goals

- **Announcing the restart to clients.** That is [RFD0019](RFD0019-planned-restarts.md). The replacement in this RFD is where Axo.app would call `axo.daemon.prepareRestart`.
- **Keeping axod alive across an Axo upgrade when its build is unchanged.** Axo restarts axod only when its build, definition or launchd state requires it, as before.
- **Automatic updates.** Axo replaces itself only when the person opens a new copy or accepts the offer.
- **Several Axos side by side**, e.g. two checkouts. The second one replaces the first.
- **Fixing `install_app`'s swap.** The swap stays atomic. Axo copes with the bundle it was registered from being moved and deleted.

## Guide-level explanation

### Vocabulary

- **launchd's Axo:** the Axo process launchd started for the agent `dev.leostera.axo.app`. It is the only Axo that stays running.
- **An opened Axo:** an Axo started any other way: Finder, `open`, the Dock. It hands over and exits.
- **Handing over:** the opened Axo makes sure launchd's Axo runs from its own bundle, asks it to show its terminal, and exits.
- **Replacing:** handing over while another Axo is running. The other one quits for good first.

### Logging in

launchd starts Axo with `--background`. The menu bar item appears, the Dock icon animates, and `DaemonController` registers or checks axod. The terminal window stays closed until the person opens it from the menu bar or the Dock.

### A crash or a kill

Axo exits by a signal, or with a non-zero status. launchd starts it again, `--background`, within its 5-second throttle. Sessions live in axod, so the terminal window comes back with them when opened. axod is unaffected.

### Quitting

- **Quit Axo** in the menu bar (⌘Q while that menu is open), or **Quit Axo** in the app menu, quits for good. Axo exits 0 and launchd leaves it alone. axod keeps running, as before.
- **⌘Q** in a window, now labelled **Close Axo Windows**, closes Axo's windows. Axo stays in the menu bar.
- Logging out, restarting or shutting down quits Axo. The system's quit event says why, and Axo lets it through.

### Opening Axo with nothing running

After Quit Axo, or on a Mac where Axo has never run, the person opens Axo.app. The opened Axo registers (or kickstarts) the agent from its own bundle. launchd starts launchd's Axo. The opened Axo asks it to show its terminal window and exits. The person sees one Axo opening its terminal, a little later than before.

### Opening Axo while it runs

If the same bundle at the same build is running, the opened Axo asks it to show its terminal, brings it forward and exits. Usually macOS does this itself and never starts the second process.

### Opening another build

The opened Axo finds Axo build 259 running from `~/Developer/github.com/leostera/axo/dist/.Axo.app.previous` (where the install moved it):

> **Replace the running Axo with build 260?**
> Axo build 259 at ~/Developer/github.com/leostera/axo/dist/.Axo.app.previous is running. Replacing it restarts axod if its build changed: terminals restart and Pi sessions resume.
> [Replace] [Keep the Running Axo]

- **Replace:** the old Axo quits for good. The new bundle's agent is registered, launchd's Axo starts from it and opens its terminal, and the opened Axo exits. launchd's new Axo checks axod's build and restarts axod if it changed.
- **Keep the Running Axo:** the running one shows its terminal, and the opened Axo exits.

### Installing over the running Axo

`bazel build //...` installs build 260 at `dist/Axo.app` while build 259 runs. The person opens `dist/Axo.app`. macOS brings the running Axo forward instead of starting the new one. The running Axo reads `dist/Axo.app/Contents/Info.plist`, sees 260, and asks:

> **Restart into Axo build 260?**
> Build 260 is installed; this is build 259. Restarting restarts axod if its build changed: terminals restart and Pi sessions resume.
> [Restart] [Not Now]

**Restart** opens a new instance of the bundle with `--replace-running`. The new instance replaces the old one without asking again. **Not Now** is remembered, in memory, until another build is installed or this Axo restarts.

### When macOS refuses

If macOS will not register the agent (it needs approval in Login Items, or it keeps refusing), the opened Axo stays and runs as before:

> **Axo will run without restarting itself**
> Axo needs approval in System Settings › General › Login Items to start at login and come back after a crash.
> Until then Axo works as usual, but won't open at login or come back if it crashes.
> [OK] [Open Login Items]

### axod after an install

launchd's Axo starts and checks axod. If launchd reports axod's job as loaded, not running and failed last time (exit 78 after a refused signature, or a deleted bundle), Axo registers axod again from its own bundle and waits for the new build. On 2026-11-01 this brought axod back about 4 seconds after Axo started, where it would otherwise have waited 30 seconds and shown "Unavailable".

## Reference-level explanation

### Components and ownership

| Component | Owns | Where |
|---|---|---|
| `dev.leostera.axo.app.plist` | when launchd starts Axo | `apple/AxoMac/Resources`, bundled at `Contents/Library/LaunchAgents` |
| `LaunchHandover` | what an Axo does as it starts (pure) | `apple/AxoDaemonManager/Sources/AxoDaemonManager/LaunchHandover.swift` |
| `AppAgentController` | finding Axos, registering the agent, stopping and waiting | `AppAgentController.swift`, same module |
| `AppLaunchHandover` | running the decision before SwiftUI, the dialogs | `apple/AxoMac/Sources/AxoMac/App/AppLaunchHandover.swift` |
| `AppQuit` | quit for good versus close windows | same file |
| `InstalledUpdateCheck` | offering a newer installed build | same file |
| `AxoURLSchemeDelegate` | reopen, terminate, notifications from other Axos | `apple/AxoMac/Sources/AxoMac/App/AxoURLSchemeDelegate.swift` |
| `DaemonController` | registering and restarting axod | `apple/AxoDaemonManager/Sources/AxoDaemonManager/DaemonController.swift` |
| `LaunchAgentDefinition`, `LaunchdJobState` | what was registered, what launchd says | `RestartMethod.swift`, `LaunchdJobState.swift` |

### Axo's agent

```xml
<key>Label</key>                  <string>dev.leostera.axo.app</string>
<key>BundleProgram</key>          <string>Contents/MacOS/Axo</string>
<key>ProgramArguments</key>       <array><string>Axo</string><string>--background</string></array>
<key>RunAtLoad</key>              <true/>
<key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
<key>LimitLoadToSessionType</key> <string>Aqua</string>
<key>ProcessType</key>            <string>Interactive</string>
<key>ThrottleInterval</key>       <integer>5</integer>
```

- `BundleProgram`, not an absolute path: launchd runs the program inside the bundle that registered the agent.
- `SuccessfulExit = false`: launchd restarts Axo after a non-zero exit or a signal, not after exit 0.
- `RunAtLoad`: at login, and when the agent is registered.
- `--background`: `AxoAppEnvironment.production` leaves the terminal window closed, unless an opened Axo asked for it (below).

`package_test` checks that the plist is bundled, lints, and names `Contents/MacOS/Axo`.

### launchd's Axo

A process is launchd's Axo when `XPC_SERVICE_NAME` is `dev.leostera.axo.app`. launchd sets it for the agent's process.

### The decision

`AppLaunchHandover.run()` is called from `AxoAppEntryPoint.main` before `AxoApp.main()`. Only the shipped app does this. `AxoMacTestHost` has its own entry point. It calls:

```swift
LaunchHandover.decide(isAgentJob:replaceRequested:current:others:) -> LaunchHandover
```

| Condition (in order) | Decision | Then |
|---|---|---|
| this is launchd's Axo | `runHere` | carry on starting |
| no other Axo | `startAgent` | hand over, exit |
| not `--replace-running`, and every other Axo runs this bundle at this build | `showRunning(pid)` | ask it to show its terminal, bring it forward, exit |
| otherwise | `replace(others, askFirst: !replaceRequested)` | ask if `askFirst`, replace, exit |

Other Axos are `NSRunningApplication.runningApplications(withBundleIdentifier:)` minus this process. Each is described as an `AxoInstance`:

- `bundlePath`: from `proc_pidpath`. This follows a bundle that was moved after the process started, so build 259 after an install reads as `dist/.Axo.app.previous`, not `dist/Axo.app`. `NSRunningApplication.bundleURL` would report the path it was launched from and read the new bundle's `Info.plist`.
- `build`: `CFBundleVersion` read from that bundle's `Info.plist` on disk.
- An instance whose path or build cannot be read is never "the same app": it gets replaced.

### Handing over

`AppAgentController.handOver(replacing:)` runs synchronously. NSApplication is not running yet, so waits spin the run loop in 100 ms steps, which lets `NSRunningApplication` update:

1. **Remove a hand-made agent.** If `~/Library/LaunchAgents/dev.leostera.axo.app.plist` exists, `launchctl bootout gui/<uid>/dev.leostera.axo.app` and delete it. Loaded from there, it would win over the bundle's, and come back at every login.
2. **Kickstart when nothing changed.** If nothing is being replaced, `SMAppService.status` is `.enabled`, and the recorded definition equals this bundle's, run `launchctl kickstart gui/<uid>/dev.leostera.axo.app` (no `-k`) and wait up to 5 seconds for launchd's Axo. This is the case after Quit Axo.
3. **Otherwise register.**
   - `launchctl bootout` the label. This stops launchd's Axo, whichever bundle registered it, without it coming back.
   - Stop the Axos being replaced (below).
   - `SMAppService.unregister()`, then `register()`. Unregistering first makes launchd load this bundle's plist even when another copy registered the agent.
   - A refused `register()` is retried up to 4 times, waiting 1, 2 and 3 seconds. Right after unregistering, or when Background Task Management first sees the agent, `smd` can log `Job is not allowed to bootstrap` and `register()` fails with EPERM. It succeeds shortly after.
   - `.requiresApproval` throws `requiresApproval`. `.notRegistered` after registering throws `registrationFailed`.
   - Record the definition (`dev.leostera.axo.app.registeredDefinition`).
   - Wait up to 20 seconds for launchd's Axo.
4. **Hand over.** Write the time to `dev.leostera.axo.app.showTerminalRequestedAt`, post `dev.leostera.axo.showTerminal`, activate launchd's Axo and `exit(0)`.

"launchd's Axo is up" means an `NSRunningApplication` with Axo's bundle ID and another pid that `isFinishedLaunching`.

If any step throws, the opened Axo shows the "will run without restarting itself" alert, sets `showTerminalRequested`, and continues starting as a normal app.

### Showing the terminal across processes

Two paths, because launchd's Axo may be starting or already running:

- **Starting:** `AppAgentController.consumeShowTerminalRequest()` runs in `AppLaunchHandover.run()` for launchd's Axo. A request less than 60 seconds old makes `opensTerminalWindow` true despite `--background`. The key is removed when read.
- **Running:** `AxoURLSchemeDelegate` observes the distributed notification `dev.leostera.axo.showTerminal` and calls `TerminalReopenRequests.shared.request()`, the same path as a Dock click.

Both may fire. Opening the terminal window twice focuses the one window.

### Replacing

`AppAgentController.stop(_:)`:

1. Post `dev.leostera.axo.quitForReplacement` with `userInfo["pids"]`. An Axo with this RFD calls `AppQuit.quitForGood()` when its pid is listed. Listing pids keeps a stale notification from quitting an Axo started afterwards.
2. Wait up to 5 seconds for the processes to exit.
3. `forceTerminate()` whatever is left, and wait up to 5 seconds more. This covers Axos from before this RFD (they don't observe the notification) and an opened Axo stuck in a dialog.

launchd's Axo has already been booted out by then, so it does not come back.

### Quitting

`AppQuit.shouldTerminate()` answers `applicationShouldTerminate`:

- `.terminateNow` after `AppQuit.quitForGood()`.
- `.terminateNow` when the current Apple Event is `kAEQuitApplication` with a `kAEQuitReason` (log out, restart, shut down).
- Otherwise close every visible window that can become main, and return `.terminateCancel`.

The app menu replaces `.appTermination` with **Close Axo Windows** (⌘Q) and **Quit Axo**. The menu bar's **Quit Axo** calls `quitForGood()`. A quit Apple Event without a reason, e.g. `osascript -e 'quit app "Axo"'`, closes windows like ⌘Q.

SIGTERM from `launchctl bootout` or `kill` is not routed through `applicationShouldTerminate`. Axo exits by the signal, and launchd restarts it unless the agent was booted out.

### Offering an installed build

`AxoURLSchemeDelegate.applicationShouldHandleReopen` calls `InstalledUpdateCheck.offerRestartIfUpdated()`. Opening the app from Finder while it runs sends reopen.

- The build this process loaded (`Bundle.main.infoDictionary`) is compared with `CFBundleVersion` read from `Bundle.main.bundleURL/Contents/Info.plist` now.
- If they differ and the person hasn't declined that build, Axo asks.
- **Restart** calls `AppUpgradeModel.restart(into:)`, which opens the bundle with `NSWorkspace.OpenConfiguration.createsNewApplicationInstance = true` and `--replace-running`. The new process decides `replace(askFirst: false)`, and the running Axo receives `quitForReplacement`.

### Upgrading from the menu bar

Added after this RFD was accepted. The menu bar shows **Upgrade to Build N** when there is a newer build (`AppUpgradeModel`, `AppUpgrade.choose`):

- **A newer build over this bundle** (a `bazel build` at `dist/Axo.app`) wins. Upgrading is the restart above.
- **Otherwise, a newer published build.** `//:publish` uploads `mac/Axo.app.json` (`{ build, axodBuild, commit }`) after the zip, served at `/cdn/Axo.app.json`. Axo reads it at launch, hourly, and when the menu opens if it is over ten minutes old. Upgrading downloads `/cdn/Axo.app.zip` and checks the whole bundle is signed as this app's bundle ID by this app's team under an Apple anchor, and that it is newer. It then swaps the bundle in as `install_app` does, keeping `.Axo.app.previous`, and restarts as above. An ad hoc signed Axo is not offered downloads.

Axo asks first only when axod's build changes, because axod's restart restarts the terminals. This is still not an automatic update: nothing is installed until the person picks the item.

### axod

Three changes to `DaemonController`, plus the signing fix.

**The definition includes the helper's signing identity.**

```swift
struct LaunchAgentDefinition: Codable, Equatable {
  var bundlePath: String
  var plistSHA256: String
  var programSigningIdentity: String?   // "<team>:<signing identifier>"
}
```

- `LaunchAgentDefinition.current(bundle:plistName:programPath:)` reads it with `SecStaticCodeCreateWithPath` and `SecCodeCopySigningInformation`. For axod `programPath` is `Contents/Helpers/axod`. For Axo's agent it is `Contents/MacOS/Axo`.
- A definition recorded before this field decodes with `nil`. It differs from every current one, so the first start after the upgrade registers axod again once.

**Axo reads launchd before waiting.** `checkBuildAndRestartIfNeeded` first computes:

- `definitionChanged`: a recorded definition exists and differs from this bundle's.
- `LaunchdJobState.read(label: "dev.leostera.axo.axod")`: `launchctl print gui/<uid>/<label>`, parsed from the job's top-level lines only. `isFailingToRun` is loaded, no `pid =`, and `last exit code` non-zero.

If either is true, Axo restarts axod with `.reregister` straight away (`daemon.reregister_needed`). Otherwise it waits for axod as before. A slow axod that is recovering Sessions is still never restarted on a timeout.

**A kickstart that doesn't take falls back to registering.** In `restartDaemon`, a kickstart that throws `kickstartFailed` or `restartTimedOut` (axod never came back with the expected build) falls through to unregister and register.

**axod stays signed as `axod`** (`bazel/apple/sign_mac_app.sh` passes `--identifier axod`). `package_test` checks it. Changing it on purpose would rely on the definition check above to register again. Every Mac would need to run a new Axo once before the new helper could start.

### Failure semantics

| Failure | What happens |
|---|---|
| Agent needs approval in Login Items | The opened Axo runs on its own and offers Login Items. It doesn't come back after a crash. |
| `register()` refused 4 times | The opened Axo runs on its own and shows the reason. |
| launchd's Axo doesn't appear within 20 s | Same: `agentDidNotStart`. The agent may still start it later, and two Axos would then run. See Unresolved questions. |
| An Axo being replaced won't quit | Force-terminated after 5 s. |
| The bundle launchd registered Axo from was deleted | Kickstart produces no Axo within 5 s, and the opened Axo registers again. |
| axod's job can't spawn (signature, deleted bundle) | Registered again on the next `DaemonController.start()`. If that fails, the status says why (`restartTimedOut`, `requiresApproval`). |
| Axo crashes in a loop | launchd restarts it every 5 s, as it would any agent. Opening a different build replaces it. |

### Invariants

- At most one Axo outlives its own startup. An opened Axo always exits, unless handing over failed and it said so.
- launchd's Axo never exits 0 except through Quit Axo, a replacement, or the session ending.
- An opened Axo never replaces a running Axo of another build without the person agreeing: in its own dialog, or in the running Axo's restart offer.
- A replaced Axo is stopped only after its agent is booted out, so launchd doesn't bring it back.
- `DaemonController` never waits on an axod job that launchd reports as failing to start.

### Observability

All under subsystem `dev.leostera.axo`:

- Category `app-agent`:
  - `app_launch.handover decision=…`
  - `app_launch.handover_failed reason=…`
  - `app_agent.handover_started replacing=N`
  - `app_agent.registered`
  - `app_agent.register_failed attempt=N reason=…`
  - `app_agent.force_terminate pid=…`
  - `app_agent.hand_made_agent_removed`
  - `app_agent.handover_succeeded pid=… [via=kickstart]`
- Category `daemon`:
  - `daemon.reregister_needed definition_changed=… launchd=running|exited_<code>|not_loaded`
  - `daemon.restart_started method=kickstart|reregister`
  - `daemon.kickstart_failed reason=…`

`log show --info --predicate 'subsystem == "dev.leostera.axo" AND (category == "app-agent" OR category == "daemon")'` tells the whole story of a start. launchd's own reasons (`OS_REASON_CODESIGNING`, `copy_bundle_path`) remain in launchd's and the kernel's logs. Axo does not read them.

## Security and privacy

- `dev.leostera.axo.showTerminal` and `dev.leostera.axo.quitForReplacement` are distributed notifications. Any process of the same user can post them. One can open Axo's terminal window. The other can quit an Axo whose pid it names, as `kill` already could. Neither carries data or reaches axod.
- The agent runs as the user, in the Aqua session, from a bundle whose signature Background Task Management checks. It adds no privilege beyond the axod agent's.
- Removing `~/Library/LaunchAgents/dev.leostera.axo.app.plist` touches only a file under Axo's own label.

## Rollout

Done on 2026-11-01, in this order:

1. `639c427`: axod is signed as `axod` again. `package_test` checks it.
2. `5a56a54`: `DaemonController` records the signing identity, reads launchd's state, and falls back from kickstart to registering.
3. `bc1cf3e`: Axo's agent, `LaunchHandover`, `AppAgentController`, `AppLaunchHandover`, `AppQuit`, `InstalledUpdateCheck`, and the menu changes. `package_test` checks the second plist.
4. `c22a448`: Mac app build 260.

Moving a Mac onto it needs one opened Axo. Axos from before this RFD don't know the handover. The first new Axo replaces them: it removes the hand-made agent if present, boots out the label, and force-terminates what's left. On this Mac that was `open -n dist/Axo.app --args --replace-running`, run once. A plain `open` can bring the old Axo forward instead.

Still to do (open on 2026-11-10; neither document says this yet):

- Update the `axo-macos-packaging` skill: the bundle embeds two LaunchAgents, an install does not reach the running Axo until it is opened and replaced, and **Quit Axo** is the only quit.
- `CONTRIBUTING.md` should say how to stop Axo for good while developing (Quit Axo, or `launchctl bootout gui/$(id -u)/dev.leostera.axo.app`).

## Testing

Unit tests (`//apple/AxoDaemonManager:AxoDaemonManagerTests`):

- `LaunchHandoverTests`:
  - launchd's Axo always runs
  - nothing running starts the agent
  - the same app is shown
  - another build is replaced after asking, and so is the same build from another path
  - an unreadable instance is replaced
  - `--replace-running` does not ask
  - a signature change re-registers
  - an old definition without a signature decodes and re-registers
- `LaunchdJobStateTests`:
  - a job that cannot spawn (exit 78) is failing
  - a running job is not
  - a clean exit 0 is not
  - a nested `pid` is not the job's
  - an unloaded job is not failing

`//apple/AxoMac:package_test` checks:

- both plists are bundled
- Axo's agent runs `Contents/MacOS/Axo`
- axod's signing identifier is `axod`
- app and helper share the team

Verified by hand on 2026-11-01:

- A plain `open dist/Axo.app` with nothing running handed over to launchd's Axo (`via=kickstart`).
- That Axo found axod's job at `exited_78`, registered it again, and axod build 23 was ready about 4 seconds after Axo started.
- Quit Axo from the menu bar exited 0 and launchd left Axo stopped.
- ⌘Q closed the windows only.
- `kill -9` on launchd's Axo brought it back within the throttle, with a new pid. axod kept its pid.
- `open -n … --replace-running` over an older Axo force-terminated it, registered the agent and handed over.

Not covered:

- The two dialogs and the restart offer have no UI test. The visual suite needs Axo closed.
- No end-to-end test runs the handover. It needs the real `SMAppService` and launchd, so it can't run in CI or alongside the person's Axo.
- Login and logout were not exercised.

## Drawbacks

- **Opening Axo starts two processes.** The opened Axo boots enough of AppKit to decide, then exits, and launchd's Axo starts. The terminal appears later than before, by one Axo launch.
- **⌘Q no longer quits.** That is deliberate, and it surprises anyone who expects a Mac app to quit on ⌘Q.
- **Axo now uses launchd's reasons without seeing them.** `LaunchdJobState` parses `launchctl print`, whose format is not an API. If it changes, `isFailingToRun` reads false and Axo falls back to waiting, as before.
- **An install still lands on a bundle launchd may follow.** Every install moves the registered bundle aside, and the next one deletes it. Axo registers again when it notices, but a crash in that window can't be recovered by launchd until the person opens Axo.
- **Registration has a retry loop** for a refusal that is not documented, and whose cause was not confirmed.
- **An old Axo is force-terminated** during the first replacement. It gets no chance to save window state.

## Rationale and alternatives

- **Do nothing, keep the hand-made agent.** It restarts Axo after Quit, can't be upgraded, and lives outside the repository. Rejected: it caused the motivating incident.
- **`KeepAlive = true` in a bundled agent.** Kills come back, but Quit becomes impossible without `launchctl`. Rejected: the person wants Quit to stay quit.
- **A login item (`SMAppService.mainApp`) instead of an agent.** Axo would open at login, but a crash or kill would not bring it back. Rejected: crashes must come back.
- **Let the opened Axo stay, and have launchd's Axo exit when it finds one.** Fewer processes at startup. But the Axo the person uses would then be one launchd doesn't restart. Rejected.
- **Quit the old Axo with a quit Apple Event** (`NSRunningApplication.terminate()`), as the 2026-10-31 upgrade in [RFD0019](RFD0019-planned-restarts.md)'s motivation did. With ⌘Q closing windows, a plain quit event no longer quits. A pid-addressed distributed notification is explicit about intent. `launchctl bootout` and `forceTerminate` cover older Axos.
- **Keep the bundle's inode across installs** (copy into the existing bundle instead of swapping). launchd would keep finding it. Rejected for now: a copy in place is not atomic, and a running Axo or Finder could see a half-written bundle. Checking launchd's state handles the deleted bundle without giving that up.
- **Detect the deleted bundle by recording the bundle's inode in the definition.** Every install would then register axod again and restart it, even when its build is unchanged, which stops terminals. Rejected in favour of asking launchd whether the job runs.
- **Read the kernel and launchd logs to explain failures.** Precise, but slow and privileged. Rejected for now. See Future possibilities.

## Prior art

- [RFD0019](RFD0019-planned-restarts.md) describes the 2026-10-31 upgrade: a Quit Apple Event to the old Axo, then a kickstart of axod. This RFD makes the first half a contract, and is where RFD0019's `prepareRestart` belongs.
- launchd's `KeepAlive` dictionary (`SuccessfulExit`, `Crashed`) is the documented way to restart on failure only. `Crashed` alone would not restart after a `kill`, so `SuccessfulExit = false` is used.
- `SMAppService` replaced `SMLoginItemSetEnabled` and hand-installed plists in macOS 13. It ties agents to the registering bundle, which is what this RFD relies on and what the deleted-bundle failure comes from.
- Apps that update in place, such as those using Sparkle, relaunch themselves after replacing their bundle. Axo can't replace its own bundle (Bazel installs it), so it offers to restart into the installed one instead.

## Unresolved questions

Before acceptance:

- Should the restart offer also appear without a reopen, e.g. when the bundle on disk changes, or only when the person opens Axo?
- Is closing windows the right meaning for a quit Apple Event without a reason? Scripts that quit Axo now need `launchctl bootout` or Quit Axo.

During implementation:

- What causes `Job is not allowed to bootstrap` right after unregistering? Is waiting the right fix, or should registration skip the unregister when the agent is already registered from this path?
- If launchd's Axo starts after the opened Axo gave up waiting (20 s), two Axos run. Should launchd's Axo replace an opened Axo it finds, or should the opened one keep waiting longer?
- Should `isFailingToRun` require more than one failed run, so a single crash of axod doesn't cause a registration?

Out of scope:

- Several Axos side by side for different checkouts.
- Automatic updates. A download from the CDN when the person picks it was added later (Upgrading from the menu bar); nothing installs without that choice.

## As built

The implementation landed on `main` with the proposal, in the commits listed under Rollout. Two problems were found while bringing this Mac back, and are already in the design above:

- The first registration was refused (`smd: Job is not allowed to bootstrap`, EPERM) 40 ms after unregistering the hand-made agent. A retry with backoff was added.
- A kickstart of an agent registered from a bundle that a later install deleted fails with `copy_bundle_path … error 0x6f`. That led to `LaunchdJobState` and to the kickstart-then-register fallback for Axo's own agent.

## Future possibilities

- Show launchd's failure reason in Settings › About when axod can't start: `OS_REASON_CODESIGNING`, a missing bundle.
- Call RFD0019's `axo.daemon.prepareRestart` from the replacement, with `reason: upgrade`, so clients see the upgrade.
- Wait for idle agents before replacing, using RFD0019's unresolved drain.
- A `bazel run //apple/AxoMac:replace` that opens the installed bundle with `--replace-running`, for development.
