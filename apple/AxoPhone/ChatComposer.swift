import AxoCore
import AxoVoice
import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    let focused: Binding<Bool>
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
    var openFiles: () -> Void = {}
    var debugAction: (() -> Void)? = nil
    var pasteAttachments: ([NSItemProvider]) -> Void = { _ in }

    @State private var hasMultipleLines = false
    @State private var showingExpandedEditor = false

    private var isTranscribing: Bool { voice.state == .transcribing }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsSend: Bool { hasDraft || hasAttachments || isTranscribing }

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
        .fullScreenCover(isPresented: $showingExpandedEditor) {
            ExpandedComposerEditor(draft: $draft)
        }
        .onChange(of: draft) { _, value in
            if value.isEmpty { hasMultipleLines = false }
        }
        .onChange(of: hasMultipleLines) { _, _ in
            let shouldRestoreFocus = focused.wrappedValue
            guard shouldRestoreFocus else { return }
            Task { @MainActor in
                await Task.yield()
                focused.wrappedValue = true
            }
        }
    }

    private var textComposer: some View {
        VStack(spacing: 4) {
            if let fileClient, !fileClient.currentDrafts.isEmpty {
                DraftFilesBar(client: fileClient, reviewUpload: reviewUpload)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            if hasMultipleLines {
                multilineInput
                actionRow
            } else {
                singleLineInput
            }
        }
        .padding(.bottom, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
        .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.16), value: hasMultipleLines)
    }

    private var singleLineInput: some View {
        HStack(spacing: 6) {
            attachmentButton
            composerEditor
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            if showsSend { sendButton }
            VoicePromptButton(voice: voice, prominent: !hasDraft && !isTranscribing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var multilineInput: some View {
        HStack(alignment: .top, spacing: 8) {
            composerEditor
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            Button {
                focused.wrappedValue = false
                showingExpandedEditor = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand message editor")
            .accessibilityIdentifier("expandComposer")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var composerEditor: some View {
        ComposerTextEditor(
            text: $draft,
            hasMultipleLines: $hasMultipleLines,
            focused: focused,
            pasteAttachments: pasteAttachments
        )
        .overlay(alignment: .topLeading) {
            if draft.isEmpty {
                Text("Message Axo")
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            attachmentButton
            Spacer(minLength: 0)
            if showsSend { sendButton }
            VoicePromptButton(voice: voice, prominent: !hasDraft && !isTranscribing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
    }

    private var attachmentButton: some View {
        Menu {
            Button("Session files", systemImage: "folder", action: openFiles)
                .disabled(fileClient == nil)
            Divider()
            Button("Camera", systemImage: "camera", action: attachCamera)
                .disabled(voice.isBusy || !canAttachPhotos)
                .accessibilityIdentifier("attachCamera")
            Button("Photos", systemImage: "photo", action: attachPhoto)
                .disabled(voice.isBusy || !canAttachPhotos)
            Button("Files", systemImage: "folder", action: attachFile)
                .disabled(voice.isBusy)
            if let debugAction {
                Divider()
                Button("Add synthetic message", action: debugAction)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 23, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Composer options")
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if isTranscribing { ProgressView().tint(.primary) }
                else { Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)) }
            }
            .foregroundStyle(canSend ? ChatColors.background : Color.secondary)
            .frame(width: 44, height: 44)
            .background(canSend ? Color.primary : ChatColors.disabledControl, in: Circle())
        }
        .accessibilityLabel(isTranscribing ? "Transcribing" : "Send")
        .accessibilityIdentifier("sendPromptButton")
        .disabled(!canSend)
        .padding(.bottom, 1)
    }
}

private struct ExpandedComposerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: String
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(.body)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Message Axo")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .accessibilityLabel("Expanded message")
                .accessibilityIdentifier("expanded-composer")
                .navigationTitle("Message Axo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { isFocused = true }
    }
}
