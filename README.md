# Axo

Axo is an agentic workspace for working with coding agents across your Mac, iPhone, and web browser. A Mac host runs agent and terminal sessions; Axo's native Mac app and companion clients let you work with those sessions from different surfaces.

> **Status:** Axo is under active development. Features, setup, and interfaces may change between releases.

## What is in this repository?

- **Mac app and host** — `apple/AxoMac/` contains the native macOS app; `crates/` contains the Rust daemon and supporting crates. The host manages agent sessions, each in its own folder, and terminal panes.
- **iPhone app** — `apple/AxoPhone/` contains the native iOS client and its UI tests.
- **Web client and service** — `packages/axo-web-app/`, `packages/axo-api-worker/`, and `sites/axo.leostera.dev/` contain the web app and its Cloudflare Worker deployment.
- **Shared protocols and Pi integration** — `packages/axo-api/`, `packages/pi-axo/`, and `schemas/` contain shared API types, the first-party Pi extension, and versioned schemas.

The Mac host owns local agent processes and terminal sessions. Remote clients communicate through the Axo service; they do not directly access the host's local files or terminal sockets.

## Setup and permissions

Axo guides you through Welcome → Setup → Connections → Ready. Setup checks this Mac’s actual permissions and explains what each enables; **Axo → Setup & Permissions…** and **Settings → Setup & Permissions** reopen the same checks. A small draggable-helper guide helps you add `axod` to the right System Settings list. Optional permissions can be skipped, unknown states are not marked allowed, and restarts always require confirmation. Connections automatically shows the local daemon and account-link status without running commands or changing Sessions. Linking an account is optional.

**Check for Updates…** opens a review window on the primary display with version details and release notes before you choose to install.

## Named Sessions (unreleased)

Agents can create a named Session in one call: `session_create({name:"axo: tests",like:"self"})`.
The optional name is saved before Pi starts and wins over automatic titles. Omit it to keep normal
Session numbering and automatic naming. Names use 1–80 UTF-16 units, with no surrounding whitespace
or control characters. Local/remote RPCs and native client APIs also accept `name`.

## Session timers

Inside an Axo Session, the MCP tools provide:

- `self({})` → `{sessionId}`, the calling Session's ID.
- `sendAfter({text, delayMs, sessionId?, delivery?})` → a timer record.
- `sendInterval({text, intervalMs, sessionId?, delivery?})` → a recurring timer record.
- `listTimers({})` lists your active timers; `cancelTimer({timerId})` cancels future firings.

The default target is self and delivery is `followUp`; `steer` and `turn` are also supported. Timers belong to the current daemon runtime: restarting axod loses them, closing sender/target cancels them, and waking after a delay does not replay missed interval ticks. Cancelling cannot retract a claimed or queued message. Scheduling returns admission, not a delivery guarantee. Existing agent prompt limits apply; an uncertain send stops recurrence rather than retrying it. Requires axod 84.

## Command line

Axo.app ships the `axo` CLI. The installer sets up `/usr/local/bin/axo`; a downloaded app offers setup once on first launch. macOS asks for administrator approval only if needed. You can also use **Axo → Install “axo” Command…** or **Settings → General → Command Line**. Existing commands and shell profiles are never replaced. Once installed, app upgrades update the command too.

```sh
axo session list
axo session create --folder . --name "axo: tests"
axo session prompt --sid <session-id> --message "Run the tests"
axo relay link ABCD-1234
```

Use `--json` for scripts, `axo capabilities` for the generated command catalog, and `--help` on any group. See [`crates/axo-cli`](crates/axo-cli/README.md) for setup, deadlines, supported operations and safety boundaries.

## Development

Axo is developed on macOS, and Bazel builds all of it: the Mac and phone apps, the Rust daemon, and the JavaScript packages and site. See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites, validation commands, and contribution guidance.

```sh
bazel build //...   # everything; the signed app lands at dist/Axo.app, the report at bazel-bin/report.txt
bazel test //...    # every test that needs no desktop, phone or browser of its own
```

The native visual UI tests require an unlocked macOS desktop and Xcode UI Automation permission. See the contributor guide before running them.

## Project notes

The repository includes implementation notes, architecture records, and design proposals under [`docs/`](docs/). Those documents may describe work in progress; the README and contributor guide are the starting points for users and contributors.

## Contributing

Bug reports, questions, and focused contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change. Do not include credentials, private session data, transcripts, or other personal data in issues or pull requests.
