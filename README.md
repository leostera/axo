# Axo

Daemon-owned Pi sessions, native Mac terminals, and a native iPhone companion.

[Accepted RFD0012](docs/rfds/RFD0012-sqlite-desired-state-and-session-materialization.md) defines central session management in Axod. The [first-slice notes](docs/first-slice.md) describe the historical single-workbench prototype, not a production fallback or permission to import its state.

[RFD0002: shared session files](docs/rfds/RFD0002-shared-session-files.md) defines explicit Mac/iPhone attachments, private R2 storage, and demand-driven history. Storage is now enabled for approved non-sensitive prototype use with direct signed uploads; the RFD's original checkpoint/deployment descriptions are historical and still need reconciliation. Physical phone paste/upload/send/Mac-read has been verified; deletion and other acceptance drills remain open.

[RFD0003: workspaces, sessions, splits, and search](docs/rfds/RFD0003-workspaces-sessions-and-search.md) records the next priority: complete and validate parallel workbenches, Mac vertical navigation and Ghostty splits, iPhone workspace/session navigation, and explicit relay routing **before** revisiting search, FFF, or the command palette. This takes precedence over executor-style service/tool integrations. The Mac foundation is implemented locally using Ghostty's Swift split primitives, with [provenance and reuse notes](apple/AxoMac/Ghostty/README.md). Broker/relay/phone integration and end-to-end acceptance remain incomplete; this is not yet a deployed multi-session feature.

[RFD0008: private multi-machine control plane](docs/rfds/RFD0008-private-multi-machine-control-plane.md) describes the next iteration of the Access-protected relay. Its [isolated API/daemon boundary](sites/api.axo.leostera.dev/README.md) routes addressed requests through [`@axo/protocol`](protocol/README.md), with authenticated machine registration and role enforcement. The legacy `service/` prototype is not a central session authority or Mac startup fallback. Historical canary/PTY connectivity checks are not native/Pi acceptance, and repository changes do not authorize deployment.

[RFD0009: protocol capability parity and native adoption](docs/rfds/RFD0009-protocol-capability-parity.md) maps the legacy/native capabilities against the new daemon route, with ownership, missing contracts and per-capability acceptance gates. It defines the next Pi/session and native-adoption slices without treating working transport as application parity.

```text
Mac / phone → addressed RPC → Axod → owned PTY → vanilla Pi + pi-axo
                local / authenticated relay
Mac libghostty ← exact terminal attachment ← Axod
```

## Pi integration boundary

Axo must work with **vanilla Pi plus an installable Axo extension**. The repository's installed Pi package is a development/test host, not a fork that Axo owns. Do not patch Pi sources, rewrite installed packages, depend on private runtime APIs, or require a replacement Pi CLI.

Pi owns steering/follow-up queues, execution, session persistence, and the authoritative transcript. The extension must use supported public APIs and retain stable command/attachment identity without guessing anchors from text or timestamps. If an API cannot express a required guarantee, document the limitation and seek an upstream extension-API improvement rather than silently bypassing it.

## Evidence boundaries

Source builds, disposable process/model fixtures, packaged native UI tests, installed launchd/service approval, deployed routing and physical-device input establish different guarantees. Historical prototype or cloud evidence is not central-client acceptance. See the [daemon test boundary](axod/tests/README.md); activation, deployment and registration repair require separate authorization.

## Layout

| Path | Purpose |
| --- | --- |
| `axod/` | Rust central desired-state authority, materializer and native PTY owner |
| `apple/AxoMacAxod/` | Production Mac delegate, service management and workbench presentation |
| `apple/AxoMac/` | Shared native terminal, sidebar, settings and voice views |
| `apple/AxoPhone/` | SwiftUI conversation and WebKit Access login |
| `apple/AxoCore/` | Shared wire types and native WebSocket client |
| `apple/AxoVoice/` | Apple on-device speech recognition and voice workflow |
| `bridge/` | Pi extension; keeps the stock interactive TUI |
| `service/` | TypeScript Worker, Access verification, one relay Durable Object |
| `shared/protocol.ts` | Validated message contract |
| `tests/` | Protocol, JWT, Workers runtime, and real Pi TUI tests |

## Install and verify

Use Node.js 22.18+ (the `cf` programmatic configuration does not run on Bun), npm, Python 3, and OpenSSL.

```sh
npm ci
npm --prefix service ci
npm run typecheck
npm test
npm run build:bridge
npm run build:service
swift test --package-path protocol
swift test --package-path apple/AxoCore
```

The shared Swift suites exercise parsed protocol boundaries and bounded client state. Validate the production Mac and phone targets with Xcode as described below; compiling the old `apple/AxoMac/*.swift` glob is not an application validation lane.

`npm test` creates temporary certificates, starts local test servers, and runs an isolated Pi TUI against a deterministic local model. It does not use your Pi configuration or model credentials. The test fixtures are not production authentication shortcuts.

## Mac application

Prerequisites:

- Full Xcode with its Metal toolchain, selected via `DEVELOPER_DIR` or `xcode-select`.
- **Zig 0.16.0**, required by the pinned Ghostty revision. Set `ZIG` to its executable if your default Zig differs.
- XcodeGen (`brew install xcodegen`, if desired).

```sh
./scripts/build-ghostty.sh
./scripts/build-mac.sh
```

If Xcode is installed but `xcode-select` still points to Command Line Tools, set `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for these commands. The development machine has a repository-local Zig at `vendor/toolchains/zig-aarch64-macos-0.16.0/zig`; select it with `export ZIG="$PWD/vendor/toolchains/zig-aarch64-macos-0.16.0/zig"` from the repository root. Neither setting changes the global toolchain.

The first Ghostty build encountered Zig's `TlsInitializationFailed` while downloading dependencies. Those archives were downloaded using certificate-verified `curl`, imported with `zig fetch` from the Ghostty checkout, and checked against their pinned package hashes. No upstream source changes or TLS-verification bypass were needed.

The build script fetches Ghostty commit `7ec9e26a29399b30ef78f06985fc75045b3cecb6` into ignored `vendor/ghostty/` and builds its full `GhosttyKit.xcframework`, not the VT-only library. Retain upstream and dependency licenses when distributing a built application.

`build-mac.sh` packages `dist/Axo.app` with the required signing identity and matching app/helper teams; no ad-hoc fallback is accepted. It does not launch the app, activate or replace an installed service, or stop running work. Package only coherent committed app/helper source after the central consumer cutover; a successful DerivedData build is not delivery or functional acceptance. See [packaging](.agents/skills/axo-macos-packaging/SKILL.md).

The production application is `apple/AxoMacAxod/`, configured by `apple/project.yml` and `apple/AxoMacAxod/Info.plist`. The obsolete pre-daemon Mac application and its frontend process/registry controllers have been removed; they are not an alternative build or runtime path. Native views and the pinned Ghostty primitives remain shared with the production target.

Axod owns the fresh central desired graph and materializes effectively open panes independently of frontend selection. Production supervision belongs to launchd. Pi is ambient interactive vanilla Pi with the installed public `pi-axo` extension; the app never launches execution or falls back to repository Pi/bridge scripts. Canonical histories remain Pi-owned. Legacy catalogs, layouts, bindings, receipts and drafts are neither imported nor used as fallback authority.

The resident frontend may hide or quit without stopping daemon work. Unsent text and attachment selections are volatile; quitting discards them. Reconnect is read-only, not service repair, installation or replay. Native/phone consumers are undergoing the central cutover, so source builds and historical prototype/cloud evidence do not establish end-to-end central application acceptance.

## Cloudflare relay and Access

There is no Axo account database or GitHub OAuth implementation in this slice. Cloudflare Access owns login and policy.

`service/cloudflare.config.ts` targets the `leostera` account and custom domain `bridge.axo.leostera.dev`. The self-hosted Access application **Axo bridge** (`5306c388-9b71-4f5b-91bf-2cf4d61bb1a8`) covers **every path on that hostname**. Its reusable **Axo — Leandro** Allow policy (`2df463f3-921a-4360-849e-fa5a3d123658`) permits only `leandro@abstractmachines.dev`; email one-time PIN is available in the account. The reusable **Axo — Mac service** policy (`d0739559-2db5-46da-8252-743611222219`) permits only the prototype Mac token. Its credentials are stored in ignored `local/relay.json` with mode `0600`; the token expires on **2026-11-07** and must be renewed or replaced before then. Restart the Mac app after initially creating credentials so Pi loads the bridge configuration.

1. Keep the user Allow policy narrowly scoped; do not add an Everyone bypass.
2. Keep the Service Auth policy restricted to the Mac token, not all service tokens.
3. Keep these **non-secret** fields in `service/cloudflare.config.ts` aligned with Access:
   - `ACCESS_TEAM_URL`: the HTTPS team origin, no trailing slash.
   - `ACCESS_AUD`: this Access application's audience tag.
   - `ACCESS_USER_EMAIL`: the allowed user's verified email claim.
   - `ACCESS_HOST_CLIENT_ID`: the Mac service token's client ID. Access puts this in `common_name`; service-token JWTs have an empty `sub`.
4. Keep `workers.dev` and preview URLs disabled so they do not become alternate entrypoints. The custom domain is attached automatically by `cf deploy` from the `domains` configuration.
5. Redeploy updated identity bindings using the project-pinned `cf` CLI:

```sh
cd service
npx cf auth login
npm run build
npm run deploy
```

Keep the existing Access guard in place when redeploying. The Access application and policies are managed separately from `cf deploy`. The Worker independently verifies JWT signature, issuer, audience, expiry, and the appropriate user/service identity before upgrading a connection. Unconfigured values must not be relaxed into a development bypass.

Create an ignored credentials file `local/relay.json` on the Mac:

```json
{
  "relayURL": "https://bridge.axo.leostera.dev",
  "accessClientId": "YOUR-ACCESS-SERVICE-TOKEN-CLIENT-ID",
  "accessClientSecret": "YOUR-ACCESS-SERVICE-TOKEN-SECRET"
}
```

```sh
chmod 600 local/relay.json
```

The bridge refuses group/world-accessible credential files. Never commit this file. `AXO_CONFIG` can select another path. Do not copy the service token into the iPhone app.

### iPhone

```sh
cd apple
xcodegen generate
open Axo.xcodeproj
```

Select the **AxoPhone** scheme, set your signing team, and run on an iPhone or simulator. The phone target builds independently of Ghostty; only the Mac target needs that framework. Running the simulator also requires an installed iOS simulator runtime.

To reproduce the unsigned builds from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd apple && xcodegen generate)
xcodebuild -project apple/Axo.xcodeproj -scheme AxoMac -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath apple/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apple/Axo.xcodeproj -scheme AxoPhone -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apple/DerivedData CODE_SIGNING_ALLOWED=NO build
```

For the unsigned device build, replace `iphonesimulator` with `iphoneos` and the destination with `generic/platform=iOS`. An unsigned device app cannot be installed on an iPhone until signing is configured.

The app defaults to `https://bridge.axo.leostera.dev` and migrates the original `.invalid` placeholder without overwriting custom endpoints. Choose **Sign in** and complete Cloudflare Access in the WebKit sheet. The app reads that sheet's `CF_Authorization` cookie into the device-only Keychain and includes it on its native WebSocket handshake. It does not assume Safari's cookie jar is shared with `URLSession`.

Access email one-time PIN is a reasonable initial login method. An identity provider that disallows embedded browser authentication may require a different native login handoff; this has **not** been verified on a real device. An expired/revoked login requires reconnect/sign-in. Do not work around it by opening the relay publicly.

The chat uses a theme-aware, conversation-first layout with formatted Markdown, user bubbles, copy/share actions, and a two-row composer with text above its controls. While Pi runs, the phone shows a thinking indicator and recent tool calls/results; messages sent during an active run use Pi's steering delivery. Provider-returned thinking text appears inline in italic gray blocks; adjacent thinking blocks are grouped as in Pi, and opaque signatures/redacted payloads are omitted. Relay configuration and sign-in are behind the **top-left connection button**, not a form above the transcript. The composer's **+** menu contains Camera, Photos, and Files; text and attachment paste use the text area's native Paste action.

**Attachments:** the composer's + menu contains **Camera / Photos / Files**. Choosing a photo or accepting a camera capture uploads a bounded JPEG snapshot automatically, without another confirmation; it does **not** send a prompt. Photo thumbnails show progress/errors and can be removed from the draft; completed uploads have no tiny status caption. Sent photos display inline, right-aligned for user messages, rather than showing a generated filename card. Individual photos preserve their aspect ratio; multiple photos form a compact, horizontally scrollable row in selection order. Tapping a sent or draft photo opens a full-screen, pinch/double-tap zoomable viewer with close, reset-zoom, and original-file export controls; draft photos can also be removed there without sending a prompt. Paste text at the cursor, or paste clipboard images/files directly into the text area: images use the automatic photo-upload flow, while files still stage locally for publication review. Settings, voice information, and session files remain in the header controls. Photos are private cloud-readable plaintext, not end-to-end encrypted: use approved non-sensitive content only. Clients upload directly to signed R2 URLs; the bridge verifies and materializes submitted snapshots on the Mac, exposes their local paths to Pi, and renders bounded image previews in capable terminals. Unavailable uploads remain drafts for explicit retry.

**Voice prompts:** on a supported **iOS 26+** device, tap the **waveform button**, confirm Apple on-device speech setup, and allow the microphone. Apple may download English language assets; progress shows **received / total bytes** when the OS reports them, otherwise a percentage. The recording bar separates **Stop** (transcribe into a reviewable draft) from **Send** (transcribe and attempt submission). If sending is unavailable, the transcript stays in the draft and is never automatically replayed. Recognition uses Apple's SpeechAnalyzer/SpeechTranscriber locally, with no server fallback or audio upload. Recording continues until stopped, interrupted, or backgrounded. FluidAudio and the Parakeet download are removed; opening this version clears Axo's old model cache. See [voice prompting](docs/voice-prompts.md) for setup, privacy, and tests.

A native WebSocket ping runs every 20 seconds. If the connection fails while Axo is active, it retries with exponential backoff (up to 30 seconds); only a valid snapshot resets the backoff, not the presence handshake. Protocol/decoding failures report a mismatch and stop retrying until reconnect, rather than looping forever. Deploy the matching relay schema, reload the Mac bridge, and then install/reconnect the phone app after protocol changes. Backgrounding intentionally disconnects, and returning reconnects with saved credentials and obtains a fresh snapshot. No push notifications yet.

Follow-up to consider: rename the protected origin to `relay.axo.leostera.dev`. This needs a coordinated DNS/Access/configuration/native-endpoint update; the currently deployed origin remains `bridge.axo.leostera.dev`.

## Try the loop

1. Start Axo on the Mac with the relay configured; confirm Pi shows `Axo: phone relay connected`.
2. Connect from the phone and verify the same conversation appears.
3. Send: “Use `axo_ask` to ask whether I want JSON or Markdown, then explain my choice.”
4. Answer on the phone and verify the local Pi dialog resolves and the response appears on both devices.
5. Repeat answering on the Mac.
6. Disconnect the Mac. The phone must show it offline; nothing should claim to be running or queued.
7. Reconnect and inspect history. Uncertain prompts are **not** automatically replayed.

## Security and intentional limits

- Access + TLS is **not end-to-end encryption**. The relay can read forwarded content. Use non-sensitive sessions until the E2EE and work-policy questions are resolved.
- No transcript, prompt queue, or model credentials are stored by the relay. It briefly holds live payloads and connection attachments; its storage is used for credential-expiry alarms.
- Only `axo_ask` questions are mirrored. Other Pi extensions' custom dialogs stay local.
- Phone history projects Pi's active branch: user/assistant text, provider-returned thinking text, and tool-specific call/result blocks. Success uses a green checkmark; shell commands, edit diffs, file paths, and searches have separate presentations. Tool results update their original call row by `toolCallId`; live assistant blocks overlay persisted history with stable IDs. The recent window targets 20 rendered blocks (attachment cards count too) within a 28,000-character / 72,000-byte budget, with compact 500-character output previews. Earlier/newer pages load only on scroll demand or explicit action; reconnect never walks the full history. A visible **Back to bottom** button jumps directly to the retained latest window. The decoded cache is bounded to 200 messages / 256 KiB. Expanding a tool fetches its recorded output in UTF-8-safe 12 KB pages; **Load more output** retrieves subsequent pages. Bash output uses Pi's full spool file when available, rather than the truncated terminal result. Missing/deleted spool files produce an explicit error. Abandoned branches are omitted from the transcript. Explicit shared-file cards have lazy text/Markdown/image/PDF previews and original-byte export; they are not a filesystem mirror or a session backup.
- A submitted acknowledgment means the bridge called Pi's message API, **not** that execution succeeded. Prompts during a run use steering semantics.
- Remote prompts are not permission-sandboxed: Pi retains its normal host capabilities. Do not expose billing-capable credentials if spending must be technically prevented.
- Terminal input/rendering and Access authentication still need physical-device testing. This is not yet a replacement for Ghostty's complete keyboard, clipboard, accessibility, and windowing behavior.
