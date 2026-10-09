import AxoVoice
import SwiftUI

struct VoicePromptButton: View {
    let voice: VoicePrompt
    let prominent: Bool
    @AppStorage("appleSpeechSetupApproved") private var downloadApproved = false
    @State private var confirmDownload = false

    var body: some View {
        Button(action: act) {
            Group {
                if waiting { ProgressView().tint(prominent ? ChatColors.background : .primary) }
                else { Image(systemName: symbol).font(.system(size: 21, weight: .medium)) }
            }
            .foregroundStyle(voice.state == .recording ? Color.red : prominent ? ChatColors.background : .primary)
            .frame(width: 44, height: 44)
            .background(prominent ? Color.primary : .clear, in: Circle())
        }
        .buttonStyle(.plain).disabled(waiting).padding(.bottom, 1)
        .accessibilityLabel(label)
        .accessibilityIdentifier("voicePromptButton")
        .alert("Set up Apple on-device speech?", isPresented: $confirmDownload) {
            Button("Continue") { downloadApproved = true; voice.prepareAndRecord() }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Uses Apple's English speech model on this iPhone. Apple may need to download language assets first; use Wi-Fi. Audio stays on-device. After you stop, Axo sends the transcript to Pi when connected; otherwise it remains in your draft.")
        }
    }

    private var waiting: Bool {
        voice.isBusy && voice.state != .recording && voice.state != .transcribing
    }
    private var symbol: String {
        if voice.state == .recording { return "stop.fill" }
        if voice.state == .transcribing { return "xmark" }
        return prominent ? "waveform" : "mic"
    }
    private var label: String {
        switch voice.state {
        case .recording: "Stop and send"
        case .ready: "Record"
        case .idle, .failed: downloadApproved ? "Record" : "Set up voice"
        case .transcribing: "Cancel transcription"
        case .requestingPermission: "Record"
        default: "Voice is busy"
        }
    }

    private func act() {
        switch voice.state {
        case .recording: voice.finishRecording()
        case .ready: voice.startRecording()
        case .transcribing: voice.cancel()
        case .idle, .failed:
            if downloadApproved { voice.prepareAndRecord() } else { confirmDownload = true }
        default: break
        }
    }
}

struct VoiceProgressCard: View {
    let voice: VoicePrompt

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: voice.state == .recording ? "record.circle.fill" : "waveform")
                        .foregroundStyle(voice.state == .recording ? .red : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.subheadline.weight(.medium))
                        if case .preparing(let progress) = voice.state {
                            if let bytes = progress.bytes {
                                Text(bytes.formatted).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else if progress.stage == .downloading {
                                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(progress.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        if let failedMessage { Text(failedMessage).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 0)
                    if voice.isBusy && voice.state != .cancelling {
                        Button { voice.cancel() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 30, height: 30) }
                            .accessibilityLabel("Cancel voice prompting")
                    }
                }
                if case .preparing(let progress) = voice.state {
                    if progress.stage == .downloading { ProgressView(value: progress.fraction).tint(.primary) }
                    else { ProgressView().tint(.primary) }
                }
            }
            .padding(14)
            .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var shouldShow: Bool {
        switch voice.state {
        case .preparing, .cancelling, .failed: true
        case .idle, .ready, .requestingPermission, .recording, .transcribing: false
        }
    }
    private var failedMessage: String? { if case .failed(let message) = voice.state { message } else { nil } }
    private var title: String {
        switch voice.state {
        case .preparing(let progress):
            switch progress.stage {
            case .checking: "Checking Apple speech"
            case .downloading: "Apple speech assets"
            case .loading: "Preparing on-device speech"
            }
        case .recording: "Recording"
        case .transcribing: ""
        case .cancelling: "Cancelling…"
        case .failed: "Voice needs attention"
        default: "Preparing voice…"
        }
    }
}

struct VoiceInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Apple on-device speech").font(.title2.bold())
                    Text("Tap the waveform or microphone to record, then tap stop and send. There is no recording time limit; long recordings use more device storage. Axo transcribes on this iPhone and sends the resulting prompt automatically when connected. If Axo is offline or cannot send, the transcript stays in your draft so you can send it later. You can dictate while the Mac is offline.")
                    Text("Recognition uses Apple's on-device SpeechTranscriber, not a server recognition service. Audio is never uploaded by Axo. Temporary recordings are deleted after transcription or cancellation; backgrounding or an audio interruption cancels capture.")
                    Text("Requires iOS 26 and a device that supports Apple's English speech model. Apple manages language assets and may download them during setup. Axo shows bytes when Apple reports byte counts, otherwise percentage progress. Apple may continue a shared asset download after you cancel setup.")
                    Text("No Parakeet, FluidAudio, Hugging Face download, or server-recognition fallback. The old Parakeet cache is removed when this version opens. This is stop-to-transcribe dictation, not live streaming.")
                    Link("About Apple's SpeechTranscriber", destination: URL(string: "https://developer.apple.com/documentation/speech/speechtranscriber")!)
                }.padding(22)
            }
            .navigationTitle("Voice prompting").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
