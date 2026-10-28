# Axo

Axo is an agentic workspace for working with coding agents across your Mac, iPhone, and web browser. A Mac host runs agent and terminal sessions; Axo's native Mac app and companion clients let you work with those sessions from different surfaces.

> **Status:** Axo is under active development. Features, setup, and interfaces may change, and this repository does not currently provide a general end-user installation or release channel.

## What is in this repository?

- **Mac app and host** — `apple/AxoMac/` contains the native macOS app; `crates/` contains the Rust daemon and supporting crates. The host manages workspaces, agent sessions, and terminal panes.
- **iPhone app** — `apple/AxoPhone/` contains the native iOS client and its UI tests.
- **Web client and service** — `packages/axo-web-app/`, `packages/axo-api-worker/`, and `sites/axo.leostera.dev/` contain the web app and its Cloudflare Worker deployment.
- **Shared protocols and Pi integration** — `packages/axo-api/`, `packages/pi-axo/`, and `schemas/` contain shared API types, the first-party Pi extension, and versioned schemas.

The Mac host owns local agent processes and terminal sessions. Remote clients communicate through the Axo service; they do not directly access the host's local files or terminal sockets.

## Development

Axo is developed on macOS. The native app and daemon build use Bazel; the JavaScript packages use npm. See [CONTRIBUTING.md](CONTRIBUTING.md) for prerequisites, validation commands, and contribution guidance.

Quick checks from the repository root:

```sh
# Rust/daemon tests
bazel test //crates/...

# JavaScript package tests and type checks
npm test
npm run typecheck

# Native Mac app and daemon build
bazel build //apple/AxoMac:AxoApp //crates/axod:axod
```

The native visual UI tests require an unlocked macOS desktop and Xcode UI Automation permission. See the contributor guide before running them.

## Project notes

The repository includes implementation notes, architecture records, and design proposals under [`docs/`](docs/). Those documents may describe work in progress; the README and contributor guide are the starting points for users and contributors.

## Contributing

Bug reports, questions, and focused contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change. Do not include credentials, private session data, transcripts, or other personal data in issues or pull requests.
