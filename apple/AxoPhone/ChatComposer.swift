import AxoVoice
import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let focused: FocusState<Bool>.Binding
    let voice: VoicePrompt
    let canSend: Bool
    let send: () -> Void
    let connectionSettings: () -> Void
    let voiceDetails: () -> Void
    var hasAttachments = false
    var attachFile: () -> Void = {}
    var attachPhoto: () -> Void = {}
    var showFiles: () -> Void = {}

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            if voice.state != .recording { VoiceProgressCard(voice: voice) }
            VStack(spacing: 4) {
                TextField("Message Axo", text: $draft, axis: .vertical)
                    .font(.body).lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 14).padding(.top, 12)
                    .accessibilityIdentifier("promptDraft")
                HStack(spacing: 8) {
                    Menu {
                        Button("Attach document", systemImage: "paperclip", action: attachFile).disabled(voice.isBusy)
                        Button("Attach photo as JPEG (2048px)", systemImage: "photo", action: attachPhoto).disabled(voice.isBusy)
                        Button("Session files", systemImage: "folder", action: showFiles)
                        Button("Paste text at end", systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { draft += text }
                        }
                        Button("Connection settings", systemImage: "network", action: connectionSettings).disabled(voice.isBusy)
                        Button("About voice", systemImage: "waveform", action: voiceDetails)
                            .accessibilityLabel("About on-device voice prompting").disabled(voice.isBusy)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("Composer options")
                    Spacer(minLength: 0)
                    VoicePromptButton(voice: voice, prominent: !hasDraft)
                    if hasDraft || hasAttachments {
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(canSend ? .black : .white.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .background(canSend ? Color.white : Color(white: 0.19), in: Circle())
                        }
                        .accessibilityLabel("Send").accessibilityIdentifier("sendPromptButton").disabled(!canSend)
                        .padding(.bottom, 1)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 27))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(.white.opacity(0.14), lineWidth: 0.75))
        }
        .padding(.horizontal, 16)
    }
}
