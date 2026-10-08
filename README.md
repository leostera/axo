# Axo

One Pi conversation, a native Mac terminal, and a native iPhone companion.

This is the **single-workbench prototype**, not the complete [RFD](docs/rfds/RFD0001-axo-continuous-agent-workspaces.md). The narrower implementation contract and limitations are in [the first-slice notes](docs/first-slice.md).

```text
Mac: libghostty → interactive Pi + Axo extension
                              ↕ WSS / Access service identity
                    Cloudflare Worker + Durable Object
                              ↕ WSS / Access user identity
                       Native Swift iPhone client
```

## Current status

- The real Pi **interactive TUI** has been exercised on a PTY with a local deterministic model: a remote prompt arrives, Pi asks a question, a remote answer resolves its local dialog, and its result returns to the phone-side connection. No paid model is used in tests.
- The relay builds with `cf`; Workers-runtime tests cover bidirectional forwarding, offline rejection, duplicate host rejection, and unauthenticated access. JWT tests cover signature, issuer, audience, expiry, and identity restrictions.
- The shared Swift library builds. Mac application sources type-check against the pinned Ghostty C headers.
- **The complete Mac/iPhone UI demo is not yet verified.** This development machine has Command Line Tools but no full Xcode, iOS SDK, or Metal toolchain. Ghostty linking, iPhone builds/signing, and real Access login must be tested with those installed.
- **Nothing has been deployed.** Access values deliberately default to an unconfigured, fail-closed state. The actual hostname/account has not been selected.

## Layout

| Path | Purpose |
| --- | --- |
| `apple/AxoMac/` | AppKit application hosting one full libghostty surface |
| `apple/AxoPhone/` | SwiftUI conversation and WebKit Access login |
| `apple/AxoCore/` | Shared wire types and native WebSocket client |
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
./scripts/check-swift.sh
```

`check-swift.sh` builds the Swift package, runs dependency-free protocol checks, and downloads **one pinned Ghostty header** into a temporary directory to type-check the Mac sources. It does not link or run a terminal. With full Xcode available, also run:

```sh
swift test --package-path apple/AxoCore
```

`npm test` creates temporary certificates, starts local test servers, and runs an isolated Pi TUI against a deterministic local model. It does not use your Pi configuration or model credentials. The test fixtures are not production authentication shortcuts.

## Mac application

Prerequisites:

- Full Xcode with its Metal toolchain, selected via `DEVELOPER_DIR` or `xcode-select`.
- **Zig 0.16.0**, required by the pinned Ghostty revision. Set `ZIG` to its executable if your default Zig differs.
- XcodeGen (`brew install xcodegen`, if desired).

```sh
./scripts/build-ghostty.sh
./scripts/run-mac.sh
```

The build script fetches Ghostty commit `7ec9e26a29399b30ef78f06985fc75045b3cecb6` into ignored `vendor/ghostty/` and builds its full `GhosttyKit.xcframework`, not the VT-only library. Retain upstream and dependency licenses when distributing a built application.

`run-mac.sh` generates the Xcode project, builds an unsigned local Mac app, and launches it with the repository/resource paths it needs. This is a development launch, not a distributable app bundle.

The terminal starts `scripts/run-pi.sh` in `local/playground/`, with its persistent Pi history at `local/playground/session.jsonl`. It uses your normal Pi model credentials/settings. Without relay credentials it runs locally.

Closing the window hides it and retains the terminal. Reopen through the Dock. **Quitting stops Pi** after confirmation; reopening resumes its saved history. This slice has no independently managed background daemon.

You can exercise the Pi bridge before the native build is available:

```sh
npm run build:bridge
./scripts/run-pi.sh
```

This fallback runs in your current terminal; it is not presented as the native Axo app.

## Cloudflare relay and Access

There is no Axo account database or GitHub OAuth implementation in this slice. Cloudflare Access owns login and policy.

Before deployment, select the account and the actual hostname (the discussed `api.axo.leostera.dev` remains a candidate). Configure a self-hosted Access application covering **every path on that hostname**:

1. A narrowly scoped Allow policy for your user identity, using your chosen Access login method.
2. A Service Auth policy for one Mac service token, without an Everyone bypass.
3. Set these **non-secret** fields in `service/cloudflare.config.ts`:
   - `ACCESS_TEAM_URL`: the HTTPS team origin, no trailing slash.
   - `ACCESS_AUD`: this Access application's audience tag.
   - `ACCESS_USER_EMAIL`: the allowed user's verified email claim.
   - `ACCESS_HOST_CLIENT_ID`: the Mac service token's client ID. Access puts this in `common_name`; service-token JWTs have an empty `sub`.
4. Attach the protected custom hostname to the Worker. `workers.dev` and preview URLs are disabled in configuration so they do not become alternate entrypoints.
5. Build/deploy using the project-pinned `cf` CLI:

```sh
cd service
npx cf auth login
npm run build
npm run deploy
```

No domain is created automatically by this repository. Keep the Access guard in place before enabling the custom hostname. The Worker independently verifies JWT signature, issuer, audience, expiry, and the appropriate user/service identity before upgrading a connection. Unconfigured values must not be relaxed into a development bypass.

Create an ignored credentials file `local/relay.json` on the Mac:

```json
{
  "relayURL": "https://YOUR-PROTECTED-HOSTNAME",
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

Select the **AxoPhone** scheme, set your signing team, and run on an iPhone or simulator. The project currently includes the Mac framework reference, so build Ghostty first when generating the whole project.

Enter the protected HTTPS origin, choose **Sign in**, and complete Cloudflare Access in the WebKit sheet. The app reads that sheet's `CF_Authorization` cookie into the device-only Keychain and includes it on its native WebSocket handshake. It does not assume Safari's cookie jar is shared with `URLSession`.

Access email one-time PIN is a reasonable initial login method. An identity provider that disallows embedded browser authentication may require a different native login handoff; this has **not** been verified on a real device. An expired/revoked login requires reconnect/sign-in. Do not work around it by opening the relay publicly.

Keyboard dictation supplies voice input; there is no Axo audio-upload service. Backgrounding the phone disconnects its socket; returning reconnects and obtains a fresh snapshot. No push notifications yet.

## Try the loop

1. Start Axo on the Mac with the relay configured; confirm Pi shows `Axo: phone relay connected`.
2. Connect from the phone and verify the same conversation appears.
3. Send: “Use `axo_ask` to ask whether I want JSON or Markdown, then explain my choice.”
4. Answer on the phone and verify the local Pi dialog resolves and the response appears on both devices.
5. Repeat answering on the Mac.
6. Disconnect the Mac. The phone must show it offline; nothing should claim to be running or queued.
7. Reconnect and inspect history. Uncertain prompts are **not** automatically replayed.

## Security and intentional limits

- Access + TLS is **not end-to-end encryption**. The relay can read forwarded content. Use a non-sensitive playground until the E2EE and work-policy questions are resolved.
- No transcript, prompt queue, or model credentials are stored by the relay. It briefly holds live payloads and connection attachments; its storage is used for credential-expiry alarms.
- Only `axo_ask` questions are mirrored. Other Pi extensions' custom dialogs stay local.
- Phone history is a bounded user/assistant-text projection. It omits tool output, thinking, images, abandoned branches, and old content beyond the size limit. Pi retains the actual history locally. Dedicated RFD/file viewing is not implemented yet.
- A submitted acknowledgment means the bridge called Pi's message API, **not** that execution succeeded. Prompts during a run use follow-up semantics.
- Remote prompts are not permission-sandboxed: Pi retains its normal host capabilities. Do not expose billing-capable credentials if spending must be technically prevented.
- Terminal input/rendering and Access authentication still need physical-device testing. This is not yet a replacement for Ghostty's complete keyboard, clipboard, accessibility, and windowing behavior.
