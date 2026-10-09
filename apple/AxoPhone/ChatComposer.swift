import AxoCore
import AxoVoice
import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let focused: FocusState<Bool>.Binding
    let voice: VoicePrompt
    let canSend: Bool
    let send: () -> Void
    var hasAttachments = false
    var attachFile: () -> Void = {}
    var attachPhoto: () -> Void = {}
    var attachCamera: () -> Void = {}
    var fileClient: SessionFilesClient?
    var canAttachPhotos = true
    var reviewUpload: (UUID) -> Void = { _ in }

    private var isTranscribing: Bool { voice.state == .transcribing }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            if voice.state == .recording {
                VoiceRecordingBar(voice: voice)
            } else {
                VoiceProgressCard(voice: voice)
                textComposer
            }
        }
        .padding(.horizontal, 16)
    }

    private var textComposer: some View {
            VStack(spacing: 4) {
                if let fileClient, !fileClient.currentDrafts.isEmpty {
                    DraftFilesBar(client: fileClient, reviewUpload: reviewUpload).padding(.top, 12)
                }
                TextField("Message Axo", text: $draft, axis: .vertical)
                    .font(.body).lineLimit(1...6)
                    .focused(focused)
                    .padding(.horizontal, 14).padding(.top, 12)
                    .accessibilityIdentifier("promptDraft")
                HStack(spacing: 8) {
                    Menu {
                        Button("Camera", systemImage: "camera", action: attachCamera).disabled(voice.isBusy || !canAttachPhotos)
                            .accessibilityIdentifier("attachCamera")
                        Button("Photos", systemImage: "photo", action: attachPhoto).disabled(voice.isBusy || !canAttachPhotos)
                        Button("Files", systemImage: "folder", action: attachFile).disabled(voice.isBusy)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 23, weight: .regular))
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("Composer options")
                    Spacer(minLength: 0)
                    VoicePromptButton(voice: voice, prominent: !hasDraft && !isTranscribing)
                    if hasDraft || hasAttachments || isTranscribing {
                        Button(action: send) {
                            Group {
                                if isTranscribing { ProgressView().tint(.primary) }
                                else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)) }
                            }
                            .foregroundStyle(canSend ? ChatColors.background : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(canSend ? Color.primary : ChatColors.disabledControl, in: Circle())
                        }
                        .accessibilityLabel(isTranscribing ? "Transcribing" : "Send").accessibilityIdentifier("sendPromptButton").disabled(!canSend)
                        .padding(.bottom, 1)
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.primary)
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
            .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}
