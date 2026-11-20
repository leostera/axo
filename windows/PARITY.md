# Windows parity roadmap

Windows is an additional Axo host and desktop client, **not a replacement for macOS or Linux**.
Existing platform functionality, public contracts, data, security boundaries and release paths
must remain supported. A Windows-only test pass is not a cross-platform release gate.

## Scope and reading the inventory

Compare against the macOS implementation in main **0.74 (`b98a1a08`)**. The scope includes the
Mac desktop, its daemon, agent-facing tools and host capabilities. iPhone/iPad/Watch are existing
clients to interoperate with, not applications to rewrite for Windows. Keep the
[Linux worklist](../linux/PARITY.md) independent and preserve its desktop and native integrations.

- **Present:** an implementation exists; not a claim of complete platform or hardware acceptance.
- **Partial:** a useful subset exists; the remaining difference is named.
- **Missing:** no equivalent is exposed by the Windows implementation.
- **Unverified:** needs its own acceptance lane; do not label it supported or missing by guesswork.
- **P0:** preservation/security/shared-contract gate. **P1:** core product parity.
  **P2:** completeness and operating experience. **P3:** visual polish.

Historical RFDs can describe proposals rather than shipped features. Use the referenced source
as the implementation baseline. Do not revive Workspaces, device enrollment or QR-bootstrap
flows that current main has retired. Account access follows [RFD0079](../docs/rfds/RFD0079-account-based-client-access.md).

## Non-regression gates — P0

- [ ] Make macOS, Linux and Windows builds and shared Rust tests required for changes to shared
  crates, schemas, build configuration and dependency locks. Keep native desktop lanes separate
  from headless unit tests; do not make another OS's tests disappear to obtain a green Windows job.
- [ ] Run the native Mac application/terminal tests and Linux desktop/computer smoke lanes before
  integration. Retain Mac signing, deployment target, Ghostty and inference dependencies; retain
  Linux GTK/Ghostty, Wayland/logind checks, CUDA and sudo-intent boundaries.
- [ ] Cover every host kind in shared serialization/schema tests. Adding `windows` must retain
  both `macos` and `linux`, including older clients' safe handling of unsupported capabilities.
- [ ] Keep the macOS minimum deployment version enforced through the platform-scoped Bazel
  configuration, without imposing Apple-only build flags on Linux or Windows.
- [ ] Run shared catalog/migration, immutable agent/conversation identity, prompt-delivery,
  cancellation, relay and credential-lifecycle contracts on every supported OS. Use adapters
  for process, terminal, credential and desktop differences rather than downgrading shared behavior.
- [ ] Treat each OS's application/agent/person distinction as a security contract, not a transport
  implementation detail. Unsupported operations must fail closed and must not be advertised.

## Feature inventory

### Open bugs from Windows 0.82.0 build 98

| Area | Evidence | Done when |
| --- | --- | --- |
| S05 / R04: Apple client shows the wrong or missing active model | Apple reads runtime model and thinking level from the Session listing. Windows lists available models and saves preferences, but its Session record omits effective runtime model metadata. | A Windows Codex Session reports the effective provider, model and supported reasoning level after default startup, explicit selection, the next turn and reconnect. Verify the serialized listing and the Apple label. Represent unknown runtime state explicitly. |
| D06: repeat installation can fail during cleanup | Staging the already-running 0.82.0 release raised an access-denied error removing a temporary copy of axod.exe. The installed app remained responsive. The cause of the file lock is unverified. | Exercise installing the same release twice while it is running. Verify the manifest, successful return, cleanup and preservation of the linked profile and live Session. |

### Sessions and agents

Mac reference: [agent adapters](../crates/axo-agent/src),
[shared Session operations](../crates/axo-server/src/ops.rs),
[Session handlers](../crates/axo-server/src/handlers.rs).
Windows reference: [backend](../crates/axo-server/src/windows.rs),
[Codex controls](../crates/axo-server/src/windows/controls.rs),
[conversation storage](../crates/axo-store/src/coding.rs).

| ID | macOS capability | Windows | Remaining work | Priority |
| --- | --- | --- | --- | --- |
| S01 | Pi, Codex, Claude Code and OpenCode adapters | Partial: Codex only | Port the other adapters with their actual capabilities, transports, lifecycle and caller identity. Never silently substitute Codex. | P1 |
| S02 | Shared Session actors, agent interface and AXP operations | Partial: separate stdio/JSON-RPC backend | Bring Windows onto the common Session/agent contracts through Windows process/PTY/IPC adapters; eliminate semantic drift without replacing Unix implementations. | P0 |
| S03 | Folder-based create, name, rename, archive and restore | Present, with API differences | Conform catalog/reopen/result semantics to the shared contract; Windows polling methods are not a drop-in AXP stream. | P1 |
| S04 | Agent TUI inside the terminal workbench | Partial: Codex chat/tool presentation | Decide and implement equivalent native agent-pane behavior, including interactive agent UIs; do not claim the WPF chat surface is the existing TUI. | P1 |
| S05 | Model/reasoning selection, steering, follow-up queue, interrupt and stop | Partial: Codex controls work; Apple runtime model reporting is incomplete | Publish effective model/effort on Session listings and updates. Extend controls according to each adapter's capabilities. | P1 |
| S06 | Agent runtime command/slash-command discovery | Missing equivalent catalog | Expose supported commands; an empty placeholder is not command parity. | P1 |
| S07 | Durable conversation identity and reconnect | Present for Codex | Retain the same conversation on every adapter's recovery path; expand failure/recovery coverage with additional agents. | P1 |
| S08 | Canonical transcript/history pipeline and ATXF integration | Present for Codex: shared ATXF native activity, stable chat identities and one desktop/relay projection | Extend to other agent adapters; preserve tool/reasoning history, prompt receipts and reply timestamps across replay, source moves and restart. Only provider-exposed reasoning is displayable. | P1 |
| S09 | Cloud-backed archived history, eviction and restoration | Partial: uploads; local projections retained | Restore cloud-only archives and implement safe retention/eviction without losing the authoritative agent conversation. | P1 |
| S10 | Idle Pi limits, dormant panes and foreground-only wake | Missing | Port idle/dormant lifecycle, wake admission and pin exemptions when Pi is supported. | P2 |
| S11 | Session brief/capability discovery | Missing shared brief | Expose the actual reachable Windows capabilities and actionable unsupported/offline states. | P1 |

### Terminals and workbench

Mac reference: [Ghostty integration and terminal policies](../apple/AxoMac/Sources/AxoMac/Terminal),
[workbench](../apple/AxoMac/Sources/AxoMac/Workbench).
Windows reference: [terminal renderer](Axo/TerminalView.cs), [pane UI](Axo/TerminalWorkspace.cs),
[ConPTY](../crates/axo-server/src/windows/panes.rs).

| ID | macOS capability | Windows | Remaining work | Priority |
| --- | --- | --- | --- | --- |
| T01 | Nested splits, persisted layout, independent shells, detach/reconnect | Present via ConPTY | Match focus/navigation, close/busy semantics and shared attachment contracts, not just layout shape. | P1 |
| T02 | Full Ghostty terminal behavior/configuration | Partial: native WPF VT subset | Close renderer/escape-sequence, Unicode cell-width, rich output and terminal configuration gaps against explicit terminal fixtures. | P2 |
| T03 | Selection, copy/paste, bracketed paste and scrollback | Present basic subset | Match selection behavior, large/Unicode paste, scroll sensitivity and bounded-history/reconnect expectations. | P2 |
| T04 | Terminal find, link handling and pointer/mouse integration | Missing or incomplete equivalents | Add find/navigation, guarded URL opening and application mouse reporting; preserve untrusted-link warnings. | P2 |
| T05 | Native accessibility and physical keyboard/IME behavior | Unverified beyond basic input | Exercise screen readers, composition, CJK/emoji, keyboard layouts and native shortcuts on real Windows hardware/RDP. | P1 |
| T06 | Shared viewport metrics, captured terminal grid and screen/write APIs | Partial: local resize and bounded byte replay | Implement shared viewport/attachment/grid semantics and agent-facing terminal screen/write operations. | P1 |
| T07 | Busy-aware shell close and Session archive | Partial: confirmation UI | Add authoritative Windows busy-state queries and captured-target decisions, including unknown-busy refusal. | P1 |
| T08 | Custom shell/agent commands and shared daemon settings | Partial: Windows-specific settings/default shell | Implement supported shared config keys and validation without inventing global preferences or rewriting user shell profiles. | P2 |

### Accounts, other hosts and agent-facing tools

Mac reference: [extension registration](../crates/axo-server/src/unix.rs),
[peer hosts](../crates/axo-server/src/peers.rs), [apps](../crates/axo-apps/src/lib.rs),
[MCP](../crates/axo-mcp/src/lib.rs), [timers](../crates/axo-server/src/timers.rs).
Windows reference: [MCP bridge](../crates/axo-server/src/windows/mcp.rs),
[relay adapters](../crates/axo-server/src/windows/relay/adapters.rs),
[remote dispatch](../crates/axo-server/src/windows/relay/remote.rs).

| ID | macOS capability | Windows | Remaining work | Priority |
| --- | --- | --- | --- | --- |
| R01 | Short-code host linking, reconnect and account-authorized answers | Present | Keep local operation account-independent and preserve human-versus-machine admission under RFD0079. | P0 |
| R02 | Unlink/disconnect account lifecycle | Missing Windows local unlink method/UI | Port shared unlink and retired-credential cleanup, including uncertain network outcomes and restart. | P1 |
| R03 | Browse account hosts/Sessions and open remote panes | Missing Windows peer UI/operations | Add peer catalog/following, remote panes, host labels and local-view versus remote-Session close distinctions. | P1 |
| R04 | Incoming account Session/prompt/terminal/model commands | Partial: Windows/Codex subset | Exercise every advertised remote operation against real existing clients, including capability-specific refusals and stale generations. | P1 |
| R05 | Full Axo MCP/SDK tool surface | Partial: `self`, own-Session `session_rename`, `computer_tools` and `computer` | Add Session discovery/control and the remaining tool families through shared contracts; keep caller scope intact. | P1 |
| R06 | Apps discovery, tool search, account selection, cloud codemode and remote MCP connections | Missing Windows daemon extension | Reuse the shared apps/account route and run limits; do not bake provider-specific catalogs into WPF. | P1 |
| R07 | Cross-Session prompts and runtime timers | Missing tool surface | Add bounded timers and caller-scoped messaging/list/cancel semantics without automatic uncertain-write replay. | P1 |
| R08 | Bounded account host shell execution (`axo.apps.bash`) | Missing: Windows route refuses it | Design the Windows shell equivalent with deadline, cancellation, process-tree cleanup and bounded output. A terminal pane or Codex shell tool is not this API. | P1 |
| R09 | Asset save/webviews and redacted conversation sharing | Partial: prompt attachments and captured-image relay uploads | Add agent-created assets/webview publication and explicit redacted sharing, with account/hash/size/path checks. | P2 |
| R10 | Portable local inference operations and model lifecycle | Missing Windows inference service | Add supported Windows generation/classification/embedding/prediction backends and capabilities. Apple-only MLX/Core ML are not Windows implementation requirements. | P2 |
| R11 | iPhone/iPad/browser/Watch interoperability | Unverified on real signed-in clients | Exercise Windows-host discovery, conversations, prompts, approvals, private input, notifications and reconnect using existing clients. | P1 |

### Permissions, computer use and private input

Mac reference: [caller policy](../crates/axo-server/src/callers.rs),
[shared computer boundary](../crates/axo-computer-use/src/lib.rs),
[questions](../crates/axo-questions/src/lib.rs).
Windows reference: [pipe security](../crates/axo-server/src/windows/security.rs),
[computer boundary](../crates/axo-server/src/windows/computer.rs),
[UIA driver](../crates/axo-computer/src/windows.rs).

| ID | macOS capability | Windows | Remaining work | Priority |
| --- | --- | --- | --- | --- |
| P01 | Local caller identity, agent scope and privileged person/app operations | Partial: SID ACLs and adjacent-image checks | Review/enforce the full caller/own-Session contract on Windows. Current unsigned same-user image checks are not equivalent to signed-app identity or sandbox isolation. | P0 |
| P02 | Agent-authored general elicitation requests and global requests UI | Partial: protected computer input/approvals and Codex questions | Expose general ask-the-person with verified asker identity, cross-Session visibility, settlement and cancellation; keep agent-authored tool-role impersonation impossible. | P1 |
| P03 | Native window reads/capture and element-targeted actions | Present native subset | Keep the allowlist capability-driven; add per-tool acceptance for every advertised action rather than infer complete Cua parity. | P1 |
| P04 | Observed-target gates, explicit confirmation, bounded sequences and revocation | Present | Preserve per-operation checks and cancellation across new tools/transports. | P0 |
| P05 | Gated in-process computer scripts | Missing: raw scripts excluded; bounded `run_steps` exists | Port script execution only when every nested action uses the same gate and redaction boundary. Never enable raw scripts as a shortcut. | P2 |
| P06 | Local Clef risk inference for flagged actions | Partial: Windows always asks when judgement is unavailable | Add a supported Windows judge if worthwhile; conservative confirmation must remain the fallback, not automatic approval. | P2 |
| P07 | Sealed, request/origin-bound private forms | Present through UIA/DPAPI | Expand browser/form acceptance while retaining changed-target refusal, no clipboard/typing fallback, single settlement and secret-free receipts. | P1 |
| P08 | Useful capture after private input | Partial: all screenshots suppressed for daemon lifetime after input | Design a safe policy before relaxing suppression; do not claim macOS masks arbitrary plain-text secrets in screenshots either. | P2 |
| P09 | Native credential protection and private cache access | Present Windows equivalents: DPAPI and protected ACLs | Expand Windows rotation/revocation/repair acceptance; preserve existing credentials and opaque data. Keychain/Secure Enclave APIs themselves are macOS-specific. | P1 |
| P10 | Locked/inactive desktop and OS permission handling | Present fail-closed probes; broader matrix unverified | Exercise lock, disconnect, UAC, integrity levels and multiple sessions/displays. No unlocking, privilege escalation or guard bypass for parity. | P0 |
| P11 | Accurate tool discovery and agent instructions | Present for the current Windows MCP surface | Keep the tool catalog and initialization guidance aligned as capabilities expand. | P1 |

### Desktop experience, installation and lifecycle

Mac reference: [application lifecycle](../apple/AxoMac/Sources/AxoMac/App),
[settings](../apple/AxoMac/Sources/AxoMac/Settings),
[palette](../apple/AxoMac/Sources/AxoMac/Palette),
[daemon manager](../apple/AxoDaemonManager/Sources/AxoDaemonManager).
Windows reference: [desktop UI](Axo/MainWindow.Desktop.cs), [controls](Axo/MainWindow.Controls.cs),
[settings](Axo/SettingsWindow.cs), [installer](Axo/Installer.cs).

| ID | macOS capability | Windows | Remaining work | Priority |
| --- | --- | --- | --- | --- |
| D01 | Sidebar grouping, pin/rename/archive, theme and shortcuts | Present local subset | Match seen/attention policy and extend to remote hosts without discarding Windows-native conventions. | P2 |
| D02 | Ranked palette across Sessions/panes/hosts and GitHub clone intents | Partial: basic local palette | Add ranking, recent ordering, peer entries, pane focus and clone-to-Session workflow. | P2 |
| D03 | OS notifications, request actions, settlement/retraction and focus routing | Partial: tray state and in-app UI | Implement Windows notifications and global request navigation; settled/expired requests must retract across clients. | P2 |
| D04 | First-run setup, actionable permissions and dependency diagnostics | Partial: manual prerequisites/settings | Add Windows readiness/setup guidance and read-only diagnostics; avoid claiming macOS TCC screens are portable UI. | P2 |
| D05 | Managed single daemon, login/startup registration and recovery | Partial: app starts an unmanaged per-user daemon; quit leaves it alive | Add opt-in Windows lifecycle ownership, singleton/version coordination and restart recovery without losing running work. | P1 |
| D06 | Immutable releases, publisher trust and safe handover/downgrade refusal | Partial: staged releases and SHA-256 manifest, unsigned | Add Authenticode/trust, installed/running version checks, deliberate handover and downgrade/data-preservation gates. Hash integrity is not publisher identity. | P1 |
| D07 | Published-release discovery and automatic update flow | Missing equivalent feed/check/download flow | Implement identity-pinned downloads, archive checks, progress, consent and restart policy; do not replace a running release in place. | P2 |
| D08 | User CLI installation and stable command routing | Missing equivalent Windows packaging/integration | Package supported commands with explicit PATH/launcher ownership; do not advertise proposed CLI inventory as implemented commands. | P2 |
| D09 | App-owned idle-sleep prevention | Missing | Add an opt-in Windows power assertion that preserves manual sleep/lock. VM provisioning settings are not an Axo feature. | P2 |
| D10 | Interactive mascot, floating/physics poses and About visuals | Partial: animated atlases and tray branding | Port desired interaction/visual behavior after functional parity; native visual implementation need not be identical. | P3 |
| D11 | Multiple monitors, DPI, touch, IME and accessibility acceptance | Unverified beyond development fixture coverage | Add real-device, display-scaling and assistive-technology acceptance, separately from RDP/headless fixture lanes. | P1 |

## Ordered delivery checklist

- [ ] **P0 — keep every existing OS working.** Establish the non-regression gates above; complete
  shared-contract and caller/security review before calling Windows a supported release.
- [ ] **P1 — unify the product core.** Address S01–S04/S06–S09, shared terminal/viewport contracts,
  R02–R08, P01/P02/P11, and managed/version-safe lifecycle. Keep each adapter cutover independently
  reviewable; do not replace working Mac/Linux paths with Windows-specific implementations.
- [ ] **P1 — real interoperability and hardware acceptance.** Cover existing account clients,
  Windows desktop/security states and physical input/accessibility. Unsupported capabilities remain
  explicit rather than silently successful.
- [ ] **P2 — complete the desktop/tooling experience.** Finish history/terminal polish, assets/sharing,
  supported inference, notifications, setup, updates, CLI integration and app-owned power policy.
- [ ] **P3 — visual parity.** Interactive/3D/physics mascot details after correctness and usability.

For each gap, completion means a supported implementation, accurate capability advertisement,
behavioral regression tests, and the relevant native acceptance lane—not a hidden control,
placeholder response, or removal of the feature on macOS/Linux. New capabilities should update
this inventory and the platform's actual discovery surface together.
