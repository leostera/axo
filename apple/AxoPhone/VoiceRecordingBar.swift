import AxoVoice
import SwiftUI

struct VoiceRecordingBar: View {
    let voice: VoicePrompt

    var body: some View {
        HStack(spacing: 12) {
            Button { voice.cancel() } label: {
                Image(systemName: "xmark").font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44).background(ChatColors.inset, in: Circle())
            }
            .accessibilityLabel("Cancel recording")
            RecordingWaveform(voice: voice).frame(maxWidth: .infinity)
            Button { voice.finishRecording() } label: {
                Image(systemName: "stop.fill").font(.system(size: 17))
                    .frame(width: 44, height: 44).background(ChatColors.inset, in: Circle())
            }
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Transcribe into your draft without sending")
            Button { voice.finishRecording(delivery: .send) } label: {
                Image(systemName: "arrow.up").font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(ChatColors.background)
                    .frame(width: 44, height: 44).background(Color.primary, in: Circle())
            }
            .accessibilityLabel("Send recording")
            .accessibilityHint("Transcribe and send; keep a draft if sending is unavailable")
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityIdentifier("voiceRecordingBar")
    }
}

private struct RecordingWaveform: View {
    let voice: VoicePrompt
    @State private var levels = Array(repeating: 0.0, count: 32)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(levels.indices, id: \.self) { index in
                        Capsule().fill(Color.secondary)
                            .frame(width: max(1, (geometry.size.width - 3 * 31) / 32),
                                   height: max(3, min(32, sqrt(levels[index]) * 32)))
                    }
                }
                .frame(height: geometry.size.height)
            }
            .onChange(of: context.date) { _, _ in
                // Only measured local amplitude; bounded display history, never
                // fabricated speech or audio sent to the relay.
                levels.removeFirst()
                levels.append(voice.audioLevel)
            }
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording audio")
    }
}
