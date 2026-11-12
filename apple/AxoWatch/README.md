# Axo Watch companion

The Watch is a companion client, not a host: it does not run Sessions or enroll as a Mac. The iPhone app embeds the Watch app. Sign in on the iPhone and open Axo on the Watch; WatchConnectivity synchronizes that same native sign-in automatically. There is no Watch login, pairing code, or separate account enrollment.

The companion verifies the account with the existing `/api/auth/me` endpoint on foreground and every 30 seconds while active. A signed-in Watch uses an acknowledged HTTPS mailbox for its account/session stream, with the same native client and conversation models as the iPhone. watchOS blocks ordinary apps from opening WebSockets (Apple TN3135); Mac/iPhone clients retain their existing WebSocket transport. It never runs an agent locally.

## Dictate into one Session

1. Sign in on the iPhone if needed, then open Axo on the Watch.
2. Tap **Choose session** and pick an existing agent Session from the account-wide **Active** and **Earlier** groups, using the shared iPhone/web classification and ordering rules. Sessions are never sectioned by machine; a machine name is only secondary row context. The Watch remembers that account, host generation, and Session across launches; it never silently switches to another Session if the chosen one disappears.
3. Tap **Dictate**. Apple's watchOS text-entry sheet provides dictation, keyboard, and Scribble where available. Dictation availability and speech processing follow the Watch's language, network, and Apple system settings; this is not the iPhone's custom on-device SpeechAnalyzer implementation.
4. Finish input, review the transcript, and tap **Send**. Cancelling does not send anything. A late dictation callback for an old selection is discarded.
5. Read the reply as it streams. Full user/assistant text is retained in the loaded history window; tool logs and reasoning are not shown. **Latest** returns to the bottom without forcibly scrolling away from what you are reading.

Prompts use the shared command-ID/retry logic and follow-up delivery, so they do not interrupt an agent already working on the Mac. Uncertain delivery is shown instead of inviting a duplicate send. Offline hosts remain readable but cannot receive a prompt. Elicitation answers, voice playback, complications, and a routing agent are not implemented; questions currently direct you to the iPhone.

## Sign-in behavior

- Keep the phone and Watch apps open for the first sync. Apple may wake the phone app for later Watch requests, but reachability and background delivery are controlled by watchOS/iOS.
- A live request establishes the phone's identity. Subsequent contexts use monotonic revisions; a delayed old sign-in cannot undo a newer sign-out.
- The Watch stores the sign-in in its own unlocked-only, this-device-only Keychain item. No credentials are logged or stored in defaults.
- Signing out on the iPhone revokes the shared server credential and sends a signed-out context to the Watch. A Watch without connectivity detects server revocation when it next reconnects; instantaneous offline revocation is not possible.
- Network failure shows **Not connected**, rather than pretending the account has signed out. A server authorization refusal clears the Watch's cached credential.
- Both apps must use the configured companion bundle relationship. The original standalone playground (`dev.leostera.axo.watch`) is a different app and does not participate in this flow.

## Build and test

From the repository root:

```sh
bazel test //apple/AxoCompanion:AxoCompanionTests //apple/AxoWatchModel:AxoWatchModelTests //apple/AxoPhone:AxoPhoneModelTests
bazel build //apple/AxoPhone:AxoPhoneApp  # simulator iPhone bundle with embedded Watch app
bazel run //apple:xcodeproj
open apple/Axo.xcodeproj
```

All targets are declared in the same generated Xcode project. Shared project generation also analyzes Mac dependencies, so an unrelated llama.cpp/sccache build problem can block generation even when both companion apps build directly through Bazel.

`apple/AxoCompanion` contains the shared sign-in parser, ordering rules, Keychain storage, Watch account model, and platform-specific WatchConnectivity adapters. `apple/AxoWatchModel` binds drafts to one remembered target and adapts the shared `PhoneWorkbench` for watchOS. `Sources/AxoWatch/` contains the Watch UI. The phone starts its companion service in `AxoPhoneApp.swift` and publishes changes whenever its credential revision changes.

## Run on devices

Xcode must already trust both devices, Developer Mode must be enabled, and the development profiles named by `apple.phone_profile` and `apple.watch_profile` in `config.json` must be installed. Profile creation/registration is an explicit Apple-account operation; the script below never does it automatically. Signing credentials and profiles stay outside Git.

```sh
xcrun devicectl list devices
apple/AxoWatch/run_device.sh <iPhone-identifier> <Watch-identifier>
```

The script builds the real signed Bazel iPhone bundle with its embedded arm64 Watch app, verifies signatures, installs and launches both apps, and checks that the newly launched Watch PID is running. It preserves bundles and JSON verification results in the temporary directory it prints. The first sign-in, if needed, is performed by the person on the iPhone; the Watch never asks for a password.

The Watch shares the iPhone build/version because Apple requires companion bundle versions to match. Its bundle ID is `dev.leostera.axo.phone.watchkitapp`.

## HTTPS relay

`AccountConnection` defaults to `RelayHTTPTransport` on watchOS and retains WebSockets elsewhere. The Watch uses protocol 2 over authenticated `POST /api/v1/account/client/http?clientId=…` requests. The ClientDO routes the same hello, Session, prompt, and record frames; no agent or new device registration runs on the Watch. Cursor acknowledgments retire mailbox frames, replayed pages are deduplicated, and connection IDs fence replaced requests. Queues are bounded and a 45-second lease releases abandoned clients. Every request rechecks the phone's shared sign-in.

```sh
bazel test //packages/axo-api-worker:http_test
bazel run //sites/axo.leostera.dev:deploy -- --dry-run --provision=false
# Production deployment requires explicit approval and a Cloudflare login:
bazel run //sites/axo.leostera.dev:deploy -- --provision=false
```

A small `Library/Application Support/watch-connection.json` report in the Watch app container contains only build, transport, connection state, and timestamps—never tokens, account IDs, Session names, transcripts, or arbitrary errors. `lastConnectedAt` records a completed account hello, not merely process launch. It can be retrieved with `devicectl device copy from` for physical-device verification.

## Verified on hardware

Build 44 (Active/Earlier picker and HTTPS transport) was installed and launched from the signed Bazel companion bundle on an iPhone 15 Pro and Apple Watch Series 10 running watchOS 26.6. Build 44's physical Watch report verified a completed authenticated HTTPS account/session handshake (`state: connected`, `transport: https`). The earlier build 41 used WebSockets and could launch but not connect on physical watchOS; build/launch success was insufficient evidence. Automated tests cover token parsing, authority/revision ordering, stale replies, sign-out, revocation, network failures, failed secure storage, target/account/host binding, draft cancellation, and refusal to reroute a disappeared Session. Existing iPhone model tests cover shared transcript streaming and prompt delivery. Actual speech recognition and the first real-account dictated prompt still require a person to speak, review, and send on the Watch; process verification alone does not assert that round trip has completed.
