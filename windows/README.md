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
The integration suite uses a deterministic Codex stand-in; it makes no model requests and
briefly opens a native terminal to test that path. Real Codex inference requires its own sign-in.

`bazel build //...` still includes the Apple apps and is not the Windows build entry point.
The Windows slice does not fetch/build Ghostty, the Metal inference sidecar, or Apple frameworks.
The current unified crate dependency resolver still resolves Cua's pinned sources.

## Use

1. Open a project folder. Axo creates a workspace and its first Codex session.
2. Send a message. Output streams into the conversation; command output and file activity appear
   while it runs. Use **Stop** to interrupt a turn. Codex's default model is used.
3. Create additional sessions with **New**. Each has a separate Codex thread and working directory.
4. **Terminal** opens an interactive PowerShell window in the session's folder. This preview uses
   a real external console, rather than an embedded terminal renderer. Axod tracks the process
   and closes it when the session closes.
5. Close the Axo window and reopen it: the daemon and running agents remain alive. Session metadata,
   completed chat messages and Codex thread IDs survive daemon restarts. Select **Reconnect**
   after a failed agent process; Axo resumes its saved thread rather than starting a new conversation.

Codex uses workspace-write with approval requests routed to the user. The client supports command
and file approvals and text questions; other server requests can be dismissed with an explicit
unsupported-interaction error. It does not silently accept an unknown request. Managed Codex
requirements still apply. Changing the application's build setup does not grant agents access
outside their configured sandbox.

The daemon's catalog is in `%LOCALAPPDATA%/Axo/server/axo.db`. It uses a local named pipe scoped
to the current Windows SID (`Axo-<SID>`), with access restricted to that user and SYSTEM, and
rejects remote pipe clients. Catalog directories use an inheritable user/SYSTEM-only ACL.
Codex process trees belong to Windows jobs so they terminate if their owning daemon dies.

For an isolated daemon:

```powershell
./dist/Axo-Windows/axod.exe --server-dir C:/axo-test/server --pipe '\\.\pipe\Axo-test' --codex C:/tools/codex.exe
```

`AXO_DAEMON` can override the client daemon executable. Closing the desktop window keeps the
daemon running. The Windows RPC method `axo.daemon.stop` shuts down the daemon and its agents.
For isolated UI testing, set `AXO_PIPE` to a local pipe's short name and `AXO_SERVER_DIR` to an
absolute scratch directory before launching the client. These overrides keep fixture sessions
out of the normal catalog.

An optional live Codex smoke test makes three small inference requests in a fresh scratch folder.
It verifies conversation continuity across a daemon restart, creates `axo-smoke.txt` in that
scratch folder, and asks Codex to read it back with a shell command:

```powershell
dotnet run --project windows/Tests/Tests.csproj -c Release -- dist/Axo-Windows/axod.exe C:/tools/codex.exe --live
```

## Scope and limits

Implemented: local workspaces, named/archived sessions, Codex conversations with streamed output,
interrupts, approvals/questions, catalog persistence, agent reconnection, and native terminals.
The pipe negotiates only methods actually implemented on Windows. Windows chat/session extensions
are additive and are not yet the generic AXP agent protocol or wire-compatible replacements for
Pi's terminal panes; the Apple client is unchanged.

Not included: remote relay/account linking, computer use, local inference, embedded terminal panes,
the Pi bridge, voice, mascot, auto-update, startup registration, or an installer. Completed chat
messages are persisted locally; live tool output is not retained across desktop restarts. A turn
interrupted by a daemon crash may have an incomplete local display, while Codex retains its own
thread history. This is a development preview, not full Mac parity.
