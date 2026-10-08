# Apple on-device iPhone voice prompts

## Using it

1. Tap the waveform in Axo's composer (VoiceOver: **Set up voice**).
2. Confirm **Set up Apple on-device speech?** and allow microphone access. Apple may need to download English language assets; use Wi-Fi and keep Axo open during setup.
3. Tap the waveform/microphone to record, speak, then tap stop (VoiceOver: **Stop and send**). There is no duration cap; long recordings use more device storage. Recording ends when you stop it, an interruption occurs, or Axo enters the background.
4. Axo transcribes on-device and sends the prompt automatically when connected. If sending is unavailable, the transcript stays in the draft for you to send later.

The app uses **SpeechAnalyzer + SpeechTranscriber on iOS 26+**, not an Apple Foundation Models text LLM. English (US) is the initial language. The device must support SpeechTranscriber's on-device model. Older or unsupported devices get an explicit message; Axo never silently falls back to server recognition. Typing remains available.

You can dictate without a relay connection once Apple's assets are installed. Sending still requires the Mac to be online. Backgrounding cancels in-progress voice work and releases the current analyzer; tap **Prepare voice** (the waveform's accessibility label) when returning. Apple's shared asset cache is managed by the OS, not copied into the Axo bundle.

## Progress

The preparation card distinguishes checking assets, downloading/installing them, and finishing setup. It displays **downloaded bytes / total bytes** when Apple's `Progress` explicitly declares file-byte progress. If Apple reports generic work units, it shows an accurate percentage instead; unknown totals get an indeterminate indicator. Generic counts such as `33 / 100` must not be presented as megabytes. There is no fabricated size or ETA.

Axo requests cancellation of setup, but Apple may continue a shared language-asset download independently. No audio is being captured during setup.

## Privacy and lifecycle

- `apple/AxoVoice/` has **no third-party package dependencies**. Its Apple adapter uses the on-device `SpeechTranscriber` module, never `SFSpeechRecognizer` or a remote speech API.
- `apple/AxoPhone/MicrophoneRecorder.swift` handles microphone permission, 16 kHz mono PCM WAV capture, interruptions, and iOS audio-session cleanup. Recording has no duration cap; ensure the device has enough free storage for long recordings.
- Temporary recordings use iOS complete file protection and are deleted after transcription, failure, or cancellation. Abrupt process termination may leave a protected temporary file for the OS to clean up.
- Cancel, backgrounding, or audio interruption discards the current recording. Late recognition results are ignored. A new operation cannot overlap cancellation cleanup.
- Each clip gets a fresh analyzer because a finalized `SpeechAnalyzer` cannot be reused. Only final results are appended; partial results do not become prompts.
- Existing draft text is preserved, including edits made while recognition runs. Over-limit drafts are not truncated; automatic sending is skipped until the draft is shortened.
- Stopping a recording explicitly initiates sending its transcript when the relay is available. If the relay is unavailable or the draft exceeds the text limit, the transcript remains in the draft for manual sending. No audio upload, paid inference, always-on listening, streaming UI, or background microphone mode is added.
- The app reserves only its English locale and does not release unrelated language reservations.

## Migration from Parakeet

The first implementation used Parakeet Unified English through FluidAudio after researching Hex. The Apple replacement removes FluidAudio, external model downloads, and their bundled notices. On launch, Axo deletes only its former `Application Support/AxoVoice/Models` cache, reclaiming the old model's disk space. Other application data and Apple's shared language assets are untouched. Setup consent uses a new preference key rather than reusing the previous third-party-download consent.

## Verification

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift test --package-path apple/AxoVoice
```

The default run tests permission denial, cancellation and late results, interruptions, recording-limit completion, draft preservation, byte-versus-unit progress, audio validation, temporary-file cleanup, and the narrowly scoped cache migration. It skips speech asset installation/inference.

For an opt-in actual Apple-model test on a supported Mac running macOS 26+, using synthetic speech generated locally by `say`:

```sh
AXO_APPLE_SPEECH_SMOKE=1 xcrun swift test --package-path apple/AxoVoice
```

This may install Apple's English assets. It transcribes the same synthetic clip twice to verify actual recognition and fresh-session handling. It does not use the microphone or any paid model. The actual-model smoke test has passed on the development Mac.

The `AxoPhone` scheme has four simulator UI tests for chat settings, copy actions, explicit speech setup consent, and the voice information sheet. These tests do not download speech assets.

```sh
(cd apple && xcodegen generate)
xcodebuild -project apple/Axo.xcodeproj -scheme AxoPhone \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath apple/DerivedData CODE_SIGNING_ALLOWED=NO test
```

**Physical-iPhone microphone capture, Apple asset installation, Bluetooth routing, and interruptions still need hands-on validation.** A successful Mac speech test is not a claim of physical-iPhone ASR verification.

## References

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [Apple's speech sample](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app)
