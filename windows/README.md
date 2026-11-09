# Axo for Windows (preview)

This branch adds a native WPF desktop client in `windows/Axo` and a Windows backend to the
existing Rust `axod` binary. It runs **Codex CLI**, using `codex app-server` over stdio. Pi is
not required. Axo reuses `axo-protocol`, the existing workspace/session SQLite catalog in
`axo-store`, and `axo-agent`; it does not replace the daemon with a C# service.

## Set up

On Windows 11 x64, install:

```powershell
winget install --id Git.Git --exact
winget install --id Bazel.Bazelisk --exact
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
winget install --id Microsoft.DotNet.SDK.10 --exact
git config --global core.longpaths true
```

Open a new PowerShell after installation. Bazel downloads the repository's pinned Rust toolchain;
do not add Cargo manifests or install the Pi agent for this client. Git Bash is required by Bazel.
The short Bazel cache path avoids Windows path-length problems. Cargo dependency resolution uses
Git CLI because the pinned Cua source contains unusually deep paths.

Install [Codex CLI](https://learn.chatgpt.com/docs/cli) and run `codex login`. The desktop client
also finds the CLI bundled with the Codex app under `%LOCALAPPDATA%/OpenAI/Codex/bin`.
To select a different executable, set `AXO_CODEX` to the full path to **codex.exe**.
Credentials stay with Codex; Axo never copies them into its catalog.

## Build and run

From the repository root:

```powershell
./windows/build.ps1 -Test -Run
```

This builds the Rust targets with Bazel, publishes the WPF client with the .NET SDK, runs Rust
unit tests and a Windows process/IPC integration suite, and opens `dist/Axo-Windows/Axo.exe`.
Pass `-BazelRoot D:/short-cache` to choose another short writable cache directory.
The integration suite uses a deterministic Codex stand-in and a loopback HTTP/WebSocket relay;
it makes no model requests. It exercises real ConPTY, DPAPI, authentication, uploads, remote
prompts/approvals/Stop, reconnect and durable command receipts. Real Codex requires its own sign-in.

`bazel build //...` still includes the Apple apps and is not the Windows build entry point.
The Windows slice does not fetch/build Ghostty, the Metal inference sidecar, or Apple frameworks.
The current unified crate dependency resolver still resolves Cua's pinned sources.

## Use

1. Use **+** or **Ctrl+N**, choose a project folder and name the Workspace. Axo creates its first Codex session.
2. Send a message. Output streams into the conversation; command output and file activity appear
   while it runs. Use **Stop** to interrupt a turn. The composer’s **⋯** menu offers model/reasoning,
   queued messages, steering and interrupt-and-send. **+** attaches files (up to eight); images go
   to Codex as images and other files as local path references. Attachments are snapshotted on send.
3. **Terminal → New Session** (**Ctrl+Shift+N**) creates another session in a chosen Workspace.
   The sidebar lists sessions across Workspaces, grouped as Pinned, Active and Earlier.
4. The workbench shows the Codex pane and an embedded PowerShell terminal side by side. **Split Right**
   (**Ctrl+Shift+D**) and **Split Down** (**Ctrl+D**) add independent terminals in a nested layout.
   **Close Terminal** (**Ctrl+W**) asks before stopping the focused shell. Ratios and shell identities
   survive a daemon restart, with new shell processes. **Ctrl+Shift+P** opens the command palette. Terminal text can be selected and copied; Ctrl+Shift+C/V copy and paste.
   **Open External Terminal** remains available. Axod owns both terminal and agent processes.
5. Closing the window hides it. The animated Axo in the Windows notification area offers **Open
   Terminal**, **Settings…** and **Quit Axo**. Windows may put this icon in the overflow area.
   Quit exits the desktop client; the daemon and running agents remain alive. Session metadata,
   completed chat messages and Codex thread IDs survive daemon restarts. Select **Reconnect**
   after a failed agent process; Axo resumes its saved thread rather than starting a new conversation.

Codex defaults to workspace-write with approval requests routed to the user. **Settings → General →
Agent permissions → Full access** selects `never` / `dangerFullAccess` on the next turn, including
already-connected sessions. This permits commands with your Windows account's access; it does not
require or request Administrator rights. The choice is local to Axo, persisted by axod, and never
changes the global Codex configuration. The client supports command
and file approvals and text questions; other server requests can be dismissed with an explicit
unsupported-interaction error. It does not silently accept an unknown request. Managed Codex
requirements still apply. Changing the application's build setup does not grant agents access
outside their configured sandbox.

The daemon's catalog is in `%LOCALAPPDATA%/Axo/server/axo.db`. It uses a local named pipe scoped
to the current Windows SID (`Axo-<SID>`), with access restricted to that user and SYSTEM, and
rejects remote pipe clients. Catalog directories use an inheritable user/SYSTEM-only ACL.
Codex process trees belong to Windows jobs so they terminate if their owning daemon dies.
ConPTY shells and their descendants also belong to jobs. PowerShell starts without a profile and
uses its native module search path, avoiding a developer parent application's injected PSModulePath.
No Windows execution-policy or publisher-trust settings are changed.

## Remote Access

Open **Axo → Settings… → Remote Access** (or **Ctrl+,**), enter the one-time `XXXX-YYYY` code
from your Axo account, and choose **Link this PC**. The default is the standard service at
`https://axo.leostera.dev`. Connection status is updated through daemon events, including automatic
reconnect and a manual Connect/Retry action. The daemon remains connected when the desktop closes.

This uses `axo-relay`, the same pairing, authenticated WebSocket, fragmentation, session uploader
and reconnect implementation as macOS. Windows host credentials are protected by per-user DPAPI
in the daemon's private directory. No credential is saved in the UI preferences or application
folder. `--relay-url` / `AXO_RELAY_URL` can select a development relay; non-loopback relays require TLS.

Completed Codex messages are projected into the relay's existing `pi/3` interchange format so
existing clients can read conversations. Codex's thread and SQLite history remain authoritative.
The host reports `windows` and only capabilities recognised by the existing production v2 service;
it never claims to be Pi. Remote clients can create/list/rename/archive sessions, send
prompts, resolve supported permission requests by their exact elicitation ID, and stop a turn they
actually saw. Command UUID receipts persist across reconnects to prevent duplicate turns.

Remote steering, interrupt-and-send, follow-up queues, verified attachments, model/reasoning selection
and nested terminal layouts use the same daemon operations as the desktop. Follow-ups are stored
in SQLite before acknowledgement, then sent when the turn finishes (or the session is reopened
after a restart). An uncertain delivery is shown as unconfirmed and is never automatically replayed.
The remote conversation currently shows a queued message once Codex consumes it; pending queue
management is available in the Windows client. The Windows host answers the account's typed AXP remote methods;
the shared relay transports them and never forwards local settings methods. Large permission requests and text questionnaires are handled
on the PC. A rejected or unsupported remote command is reported as an error rather than accepted
and discarded. Linking a real account requires the user's fresh pairing code; tests use an isolated relay.

## Computer use

Enable **Settings → General → Agent permissions → Allow computer use on this PC**. The choice
applies to local sessions and the paired account; pairing alone does not enable it. Disabling it
revokes subsequent calls immediately and cancels pending permission requests. Windows computer use
runs through the pinned Cua UI Automation / Win32 runtime in the Rust daemon, with the same tool
names used on Mac. No additional desktop service, browser extension or elevated scheduled task is
installed. Bazel downloads Microsoft's checksum-pinned Spectre CRT link libraries when building
the Windows driver, so a second elevated compiler installation is not required.

Every Axo-owned Codex app-server receives a per-process MCP configuration pointing at
`axod mcp --pipe <this daemon> --session <this session>`. It connects to the running daemon and
exposes `computer_tools` (schemas) and `computer` (one call), including inline screenshots. Agents
can inspect app windows, read UI elements, take screenshots, set field values, click, scroll and
send keys to a specific window. Use fresh `get_window_state` results and returned element tokens
before acting. Windows validates that the window belongs to the specified process.

The production relay interfaces `axo.apps.computer.status` and `axo.apps.computer` use the same
backend and gate. Screenshot replies upload image assets with the existing host credential and
return attachment references. The standard Axo account and existing pairing continue to work.

The shared word-based action gate asks about flagged actions and honors `confirm: true`; the
person answers in Axo's approval panel or through the authenticated relay. Windows does not run
the Mac Clef inference helper, so flagged actions require an answer. A question expires, cancels
when its MCP call disconnects, and cannot authorize a different or later call. Local permission
changes and computer approvals are accepted only from the adjacent `Axo.exe` process, never from
the MCP bridge. This peer check is not isolation from arbitrary code running as the same Windows
user, which can already modify the user's application files.

Computer tools cannot act on Axo's own UI, use desktop-scope input, unlock the PC, dismiss UAC,
or bypass Windows integrity boundaries. **run_steps** supports up to 32 sequential operations,
with a shared deadline and the same per-operation gates; it stops on error, decline or revocation.
Raw scripts and nested sequences remain unavailable. The word gate is not a complete semantic safety reviewer. Full Access
for shell commands remains separate from the computer-use opt-in and its permission requests.

**request_input** presents fields identified from a retained UI Automation form. Local answers go
directly from Axo to the protected pipe; remote answers use the shared device-signed HPKE envelope,
with the host key protected by DPAPI. Axo checks the window, field identities and browser document
origin again before filling through ValuePattern. It refuses forms that cannot be verified; no
clipboard or keyboard fallback is used. The agent receives a receipt, not the entered values.
Filled values are masked in subsequent computer text reads. After an input request, screenshots
are suppressed for that daemon lifetime because Windows does not yet have pixel-level secret
redaction. Redaction memory does not persist across daemon restart. This protects computer-tool
results, not arbitrary shell commands allowed by Full Access.

## Install and update

**Settings → About → Install This Build** verifies the bundled SHA-256 manifest, stages a release
under %LOCALAPPDATA%/Programs/Axo/releases, and adds a Start menu shortcut. **Update from Package…**
accepts a locally selected Axo ZIP with the manifest at its root. Neither action needs Administrator
rights, stops a process, nor replaces the running release. Relaunch and restart the daemon when
you are ready; terminal processes and active turns stop at that point. Previous releases remain
on disk. There is no automatic download/update feed, startup registration or Authenticode signature
yet; the manifest checks package integrity, not publisher identity.

## Mac interface reference

The Windows client follows the committed Mac interface rather than adding a separate design:

| Mac source | Windows implementation |
| --- | --- |
| `WorkbenchSidebar`, `SessionSidebarRow` | 220-DIP sidebar, 26-DIP host header, 22-DIP single-line rows, status/glyph/name/age, pin/rename/archive menu, collapse toggle |
| `TerminalWorkbenchView`, `TerminalSplitView` | 1000×680 window, minimum 760×480, edge-to-edge panes and a one-pixel split divider |
| `SettingsView`, `RemoteAccessSettingsView` | 180-DIP Settings sidebar; Appearance, Remote Access and About use the same content and section names, with PC/Windows wording |
| `LaunchSplashView`, `AxoApp` | Original animated loader, happy reveal, app icon and notification-area Mark; Open Terminal / Settings / Quit menu |
| `GhosttyRuntime+Config` | 2-DIP horizontal / 10-DIP vertical terminal padding; pinned Ghostty default background `#282C34` and foreground `#FFFFFF` |

Native chrome uses the Windows system appearance and accent; Settings → Appearance offers
System/Light/Dark. The default terminal colors match the [pinned Ghostty configuration](https://github.com/ghostty-org/ghostty/blob/81598385d608dda4946093d6d6a234d204a2f225/src/config/Config.zig#L575).
The shell renderer is a native WPF VT surface over ConPTY, not Ghostty. The Codex pane renders
app-server messages and tool activity in the same terminal workbench layout; it is not Pi's TUI.

`Assets/AppIcon.png` is copied unchanged from the Mac app icon. Animation atlases are rendered
from the committed `assets/mascot/axo.riv`, using its Mark, Icon, Face and Loader artboards and its
happy input. Playback is 30 fps and respects Windows reduced-animation preferences. Regenerate with:

```powershell
pnpm --dir packages/axo-mascot install --ignore-workspace --ignore-scripts --lockfile=false
node windows/tools/generate-mascot.mjs
```

Regeneration needs Chrome and the mascot package's development dependencies. Normal builds use
the committed atlases and need neither. The port includes the original idle/blink, loading and
happy poses; interactive pointer tracking and the Mac About pane's experimental 3D mascot are not ported.

For an isolated daemon:

```powershell
./dist/Axo-Windows/axod.exe --server-dir C:/axo-test/server --pipe '\\.\pipe\Axo-test' --codex C:/tools/codex.exe
```

`AXO_DAEMON` can override the client daemon executable. Closing the desktop window keeps the
daemon running. The Windows RPC method `axo.daemon.stop` shuts down the daemon and its agents.
For isolated UI testing, set `AXO_PIPE` to a local pipe's short name and `AXO_SERVER_DIR` to an
absolute scratch directory before launching the client; `AXO_DESKTOP_CONFIG` can isolate UI preferences.
These overrides keep fixture sessions
out of the normal catalog.

An optional live Codex smoke test makes four small inference requests in a fresh scratch folder.
It verifies conversation continuity across a daemon restart, creates `axo-smoke.txt` in that
scratch folder, and asks Codex to read it back with a shell command. It then uses Axo's MCP tools
to read and edit a separate owned WPF fixture window and independently verifies the field value:

```powershell
dotnet run --project windows/Tests/Tests.csproj -c Release -- dist/Axo-Windows/axod.exe C:/tools/codex.exe --live
```

## Scope and limits

Implemented: local workspaces, named/archived sessions, Codex conversations with streamed output,
interrupts, approvals/questions, catalog persistence, agent reconnection, embedded ConPTY terminals,
Mac workbench structure, original animated branding, a tray app, and relay/account linking.
The pipe negotiates only methods actually implemented on Windows. Windows chat/session extensions
are additive and are not yet the generic AXP agent protocol or wire-compatible replacements for
Pi's terminal panes; the Apple client is unchanged.

Not included: raw computer scripts, local inference, the Pi bridge, voice,
full Ghostty terminal features/configuration, automatic updates or startup registration. Completed chat
messages are persisted locally; live tool output is not retained across desktop restarts. A turn
interrupted by a daemon crash may have an incomplete local display, while Codex retains its own
thread history. Terminal replay is bounded to 2 MiB per shell and the native VT surface is a
basic terminal renderer. Mac, physical IME and real-device relay interoperability need their own
validation lanes. This is a development preview, not full Mac parity.
