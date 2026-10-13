# Axo

Axo is a native macOS and iPhone client for sessions owned by the local Axod service. Axod is the authority for desired session state, owned PTYs, Pi admission, and submitted operations; clients present bounded observations and issue addressed requests.

The accepted design is [RFD0012](docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md). The private addressed API and shared wire contracts live in [`sites/api.axo.leostera.dev`](sites/api.axo.leostera.dev/README.md) and [`protocol`](protocol/README.md). Earlier RFDs describe historical design context and are not evidence that every planned client flow is currently available.

```text
Native Mac / iPhone → addressed RPC → Axod → owned PTY → ambient vanilla Pi
                                      ↕
                              desired-state store
```

Axod uses ambient interactive vanilla Pi with the installed public `pi-axo` extension. Axo does not bundle or launch an alternate Pi, use Pi RPC mode, patch installed Pi sources, or start execution from a client. PTY attachment and Pi history remain owned by Axod and Pi respectively.

## Repository layout

| Path | Purpose |
| --- | --- |
| `axod/` | Rust daemon, central desired-state authority, materializer, RPC, PTY and Pi integration |
| `protocol/` | Shared TypeScript/Swift wire contracts and schema tests |
| `sites/api.axo.leostera.dev/` | Access-protected addressed API and isolated Worker/daemon fixtures |
| `pi-axo/` | Public extension loaded by ambient interactive Pi |
| `apple/AxoMacAxod/` | Native Mac application and Axod workbench |
| `apple/AxoPhone/` | Native iPhone application; central conversation cutover is still in progress |
| `apple/AxoCore/` | Shared native client state and transport |
| `apple/AxoVoice/` | On-device voice capture and transcription |
| `vendor/ghostty/` | Pinned Ghostty sources/framework used by the Mac terminal |

## Development and validation

Requirements depend on the lane: Rust/Cargo, Node/npm, full Xcode and the pinned Ghostty build toolchain. From the repository root:

```sh
npm ci
npm --prefix protocol test
npm --prefix sites/api.axo.leostera.dev test
npm run test:pi-control
npm run test:pi-discovery
npm run test:pi-interactive
cargo test --manifest-path axod/Cargo.toml --locked --offline
cargo clippy --manifest-path axod/Cargo.toml --all-targets --locked --offline -- -D warnings
swift test --package-path protocol
swift test --package-path apple/AxoCore
```

`npm test` aggregates the shared-protocol, isolated API, and Pi extension/discovery suites. `npm run test:pi-interactive` launches only its owned disposable PTY/Pi fixtures. The API and daemon test guides describe fixture ownership and what each lane does not establish. Tests do not authorize contacting or changing live services, installing helpers, or using production credentials.

Generate the Xcode project and build native targets using `apple/project.yml` and the scripts in `scripts/`. Mac app packaging is restricted to coherent committed source and the required signing identity; packaging does not install, activate, or relaunch a service. Simulator and component tests do not establish physical-device acceptance.

## Authority and safety boundaries

- A fresh central store is authoritative. Legacy catalogs, preferences, histories, bindings, drafts, and service credentials are not imported or read as session authority.
- Connection and refresh are read-only. Missing runtime or an uncertain response is not evidence of completion, permission to retry, or a reason to create replacement work.
- Submitted commands are captured against exact targets and revisions. Only their exact immutable originals reconcile uncertain outcomes; user drafts and attachment selections remain volatile.
- Runtime availability is an observation, not proof of Pi admission or completion. An unresolved operation stays fenced rather than being fabricated as successful.
- Historical RFDs and deployment notes are design records, not authorization. Installed-service activation, cloud deployment, physical-device installation, and stronger crash/VT acceptance are separate gates.

The primary phone conversation and several native lifecycle flows are still undergoing central cutover. Do not treat a build, fixture, preview, previously deployed endpoint, or historical acceptance note as proof of end-to-end product parity.
