# Axo Watch companion

The Watch is a companion client, not a host: it does not run Sessions or enroll as a Mac. The iPhone app embeds the Watch app. Sign in on the iPhone and open Axo on the Watch; WatchConnectivity synchronizes that same native sign-in automatically. There is no Watch login, pairing code, or separate account enrollment.

The companion verifies the account with the existing `/api/auth/me` endpoint on foreground and every 30 seconds while active. A signed-in Watch uses an acknowledged HTTPS mailbox for its account/session stream, with the same native client and conversation models as the iPhone. watchOS blocks ordinary apps from opening WebSockets (Apple TN3135); Mac/iPhone clients retain their existing WebSocket transport. It never runs an agent locally.

## Talk into one Session

1. Sign in on the iPhone if needed, then open Axo on the Watch.
2. Choose an existing agent Session from the account-wide **Active** and **Earlier** groups, using the shared iPhone/web rules. Machines are secondary row labels, never groups. The account-bound selection and title survive relaunches; the in-memory catalog and conversation survive foreground changes. The same Session can reopen after its Mac restarts, but an old recording cannot cross that host-generation boundary. A disappeared Session never silently reroutes.
3. Tap the **microphone** and allow microphone access on the Watch. A fixed 44-point bottom row shows small Cancel/Send icons and a 10-point metered waveform—no system dictation sheet, keyboard, or live transcript. The conversation occupies the remaining height and stays scrollable with the Digital Crown throughout preparation, recording, and transcription; its Session title sits in a quiet, single-line label at the very bottom. Your messages—including pending and queued prompts—use right-aligned blue bubbles like iPhone, with agent replies on the left. Tools, reasoning, and empty messages are filtered before layout, rather than leaving blank rows. Recording is capped at 90 seconds.
4. Tap **↑ Send** to stop the microphone, transcribe on the paired iPhone, and send directly to that Session. There is no review sheet. **× Cancel** discards the attempt, including during transcription. An unsent message remains explicitly retryable without displaying a transcript preview.
5. Read the streamed conversation. Tools and reasoning remain hidden. Scroll with the Digital Crown; there is no Latest/down-scroll button.

watchOS cannot use Apple's Speech framework. Audio is recorded locally as bounded mono AAC and leaves the Watch **only after Send**. Short recordings use an immediate WatchConnectivity data message; longer recordings and unreachable-message fallbacks use its queued file transport. The iPhone copies incoming temporary files before the delegate returns, runs on-device SpeechAnalyzer/SpeechTranscriber, and returns a request-bound result. Audio is not uploaded to a cloud transcription service. Local temporary recordings are removed on completion/cancellation; the OS manages residual temporary storage after a process crash. Speech models may need Apple's asset download on first use. Keep the paired iPhone nearby; if unavailable, nothing is sent. Phone activation occurs at application launch, including background wakes. Locked-Keychain unavailability is not mistaken for sign-out; non-secret metadata can recognize the already published Watch identity for local transcription only, never grant API access.

Requests/results are bound to the account, exact sign-in fingerprint, request ID, and expiry. Cancellation fences late callbacks. Audio/file size, duration, reply size, cached replies, and outstanding work are bounded.

Prompts use the shared command-ID/retry logic and follow-up delivery, so they do not interrupt an agent already working on the Mac. Uncertain delivery is shown instead of inviting a duplicate send. Offline hosts remain readable but cannot receive a prompt. Elicitation answers, voice playback, complications, and a routing agent are not implemented; questions currently direct you to the iPhone.

Agent replies use the same parsed Markdown blocks and inline styles as iPhone: headings,
paragraphs, bullets/numbered lists, quotes, rules, code fences, and tables. Code wraps for the small
screen; tables become labeled row cards rather than requiring sideways scrolling. Bold, italics,
inline code, and web links retain their styles. Links do not fetch anything automatically, and
only HTTP(S) URLs may open from the renderer.

## Brand and watch-face mascot

The Watch uses Axo’s existing app-icon artwork, Fredoka wordmark, and actual Rive mascot frames.
The mascot lives in the app header; tapping it gets a small happy reaction, respecting Reduce
Motion. It is not a separate drawing or a bundled Rive runtime.

A lightweight WidgetKit extension provides the mascot for **circular** and **corner** complication
slots. On the Watch, edit a compatible face → Complications → select a small circular/corner slot
→ **Axo**. Tapping the mascot opens the app and its remembered session; it never starts recording.
The complication is a static launcher, not a live status indicator: no polling, shared credentials,
account details, or microphone access. WidgetKit controls its tint and Always On rendering.

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

`apple/AxoCompanion` contains shared authentication, ordered snapshots, bounded voice messages, phone file transcription, and WatchConnectivity adapters. `apple/AxoWatchModel` binds drafts to one remembered target and adapts `PhoneWorkbench`. `apple/AxoVoiceUI` shares the metered waveform with the phone. `Sources/AxoWatch/` contains the Watch UI and recording engine. `AxoPhoneLifecycle` starts the shared phone environment before window creation; credential changes publish new snapshots.

## Run on devices

Xcode must already trust both devices, Developer Mode must be enabled, and the development profiles named by `apple.phone_profile`, `apple.watch_profile`, and `apple.watch_complication_profile` in `config.json` must be installed. Profile creation/registration is an explicit Apple-account operation; the script below never does it automatically. Signing credentials and profiles stay outside Git.

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

## Verification

Build 44 verified authenticated HTTPS connectivity on an iPhone 15 Pro and Apple Watch Series 10 (watchOS 26.6), followed by a person-sent Watch message and reply. Build 41's WebSocket version could launch but not connect, so launch alone is not connectivity evidence.

Build 45 adds custom recording/phone transcription, warm-session continuity, and automatic same-Session restoration after a Mac restart. Its signed device bundle builds, installs on both devices, and launches on the physical Watch. Build 45's physical connection report verified `state: connected`, `transport: https`, and a completed account hello at `2026-11-12T20:12:10Z`. Automated tests cover authentication, account/host fencing, cached selection/title, suspend retention, stale voice requests/replies, audio message budgets, no speech, oversized input, and locked-phone identity/sign-out behavior. The actual SpeechAnalyzer file path was separately exercised on this Mac using synthetic hello-world speech; it recognized the expected words in about five seconds. Run that opt-in integration check with:

```sh
say -o /tmp/axo-watch-synthetic-voice.aiff 'Hello world. This is a test message from my watch.'
bazel test //apple/AxoCompanion:AxoCompanionTests \
  --test_filter='CompanionVoiceTests/testRealSpeechFixtureWhenRequested' \
  --test_env=AXO_REAL_SPEECH_FIXTURE=/tmp/axo-watch-synthetic-voice.aiff \
  --strategy=TestRunner=local --test_timeout=180
```

Build 46 restores brand assets and embeds the signed WidgetKit mascot extension. Its real Bazel
bundle installed on the iPhone and Watch and the Watch process launched successfully. Its
physical report recorded a completed HTTPS account hello at `2026-11-12T20:30:47Z` before
normal wrist-down suspension. The extra
development identifier/profile was created only after explicit approval. Physical watch-face
selection/rendering still needs a person to add the complication; installation alone does not
prove the complication has been selected or rendered.

A person reported sending a spoken message from the physical Watch on build 46, confirming the recording → WatchConnectivity → iPhone transcription → Session prompt path. This is user-reported hardware evidence, separate from the Mac file-transcription tests.

Build 47 keeps that same voice pipeline but moves its controls into a compact bottom bar. The conversation ScrollView is no longer replaced during capture, and the recording-specific Axo title is removed in favor of the Session title. The person subsequently reported that this still did not give the intended physical UX.

Build 48 replaces the inset with an explicitly sized footer sibling of the persistent conversation.
The waveform is clipped to 14 points including its padding, with 28-point visual buttons inside
44-point touch targets. Sending/queued prompts now retain their full words in user bubbles;
regression tests cover both sides and hidden tool/reasoning/empty rows. Device launches explicitly
terminate the prior app process. `Library/Application Support/watch-layout.json` records only the
runtime layout marker, build, voice activity flags, and measured conversation/footer heights—no
message content or identifiers. It supports checking the physical layout rather than inferring
it from launch success. The person subsequently confirmed the two-sided chat was working on the physical Watch.

Build 49 adds block-level Markdown rendering using the shared iPhone parser and moves the Session
title below the voice controls, removing the top title. Shared parser/conversation tests and the
signed device build pass. After intermittent CoreDevice tunnel failures, a retry installed and
fresh-launched build 49 on the physical Watch. Its runtime layout report confirmed build 49 and
`fixed-footer-v3-markdown`. This verifies the running version, not a visual inspection of Markdown
or the title placement; those still need the person's check.
