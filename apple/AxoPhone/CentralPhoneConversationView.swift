import AxoCore
import AxoProtocol
import AxoVoice
import SwiftUI

private struct CentralVoiceDestination {
    let capture: CentralEditCapture
    let presentationID: UUID
    let draft: String
}

@MainActor
struct CentralPhoneConversationView: View {
    @Bindable var model: CentralPhoneWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var voice = VoicePromptFactory.make()
    @State private var voiceDestination: CentralVoiceDestination?
    @State private var editorBinding: CentralPiBindingTarget?
    @State private var editorPresentationID: UUID?
    @State private var voiceNotice: String?
    @State private var unappliedTranscript: String?

    private var session: CentralSessionView? {
        guard let id = model.conversationSessionID else { return nil }
        return model.selectedCatalog?.sessions.first { $0.session.sessionId == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.isLoadingConversation && model.conversationHistory.isEmpty {
                            ProgressView("Loading Pi conversation…")
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        if let observation = model.conversationObservation,
                           case .piObservation(.notAdmitted) = observation.payload {
                            ContentUnavailableView(
                                "Pi is not admitted",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Axod has not established this conversation. Opening it will not start or replace Pi.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 180)
                        }
                        ForEach(model.conversationHistory, id: \.entryId) { entry in
                            CentralHistoryEntryRow(entry: entry)
                                .id(entry.entryId)
                        }
                        if let notice = model.conversationNotice {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }
                        if let voiceNotice {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(voiceNotice).font(.footnote).foregroundStyle(.orange)
                                if let unappliedTranscript {
                                    Text(unappliedTranscript)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .refreshable { await model.refreshConversation() }
                .onChange(of: model.conversationHistory.last?.entryId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            if let state = liveState {
                if let question = state.question {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.title).font(.headline)
                        ForEach(question.options, id: \.id) { option in
                            Button(option.label) {
                                guard let editorPresentationID, let editorBinding else { return }
                                Task {
                                    await model.answerConversationQuestion(
                                        optionID: option.id,
                                        presentationID: editorPresentationID,
                                        binding: editorBinding
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!editorIsCurrent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                } else if state.busy, state.interactionId != nil {
                    Button("Cancel response", systemImage: "stop.circle") {
                        guard let editorPresentationID, let editorBinding else { return }
                        Task {
                            await model.cancelConversationInteraction(
                                presentationID: editorPresentationID,
                                binding: editorBinding
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!editorIsCurrent)
                    .padding(.vertical, 8)
                }
            }

            composer
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(session?.session.name ?? "Pi conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") {
                    model.closeConversation()
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshConversation() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoadingConversation)
                .accessibilityLabel("Refresh Pi conversation")
            }
        }
        .task { await model.refreshConversation() }
        .onAppear { captureEditorBindingIfNeeded() }
        .onChange(of: model.conversationObservation?.revision) { _, _ in captureEditorBindingIfNeeded() }
        .onChange(of: voice.transcript) { _, transcript in receive(transcript) }
        .onChange(of: voice.state) { _, state in
            if !voice.isBusy, voice.transcript == nil { abandonVoiceDestination() }
            if case .failed = state { voiceNotice = "Voice transcription failed. No request was sent." }
        }
        .onDisappear {
            abandonVoiceDestination()
            voice.cancel()
            editorBinding = nil
            editorPresentationID = nil
            model.closeConversation()
        }
    }

    private var composer: some View {
        Group {
            if voice.state == .recording {
                VoiceRecordingBar(voice: voice)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    VoiceProgressCard(voice: voice)
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Message Pi", text: draftBinding, axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                            .focused($composerFocused)
                            .accessibilityIdentifier("central-pi-composer")
                            .disabled(!model.isConnected || liveState == nil || liveState?.question != nil || voice.isBusy || !editorIsCurrent)
                            .onSubmit { submit() }
                        VoicePromptButton(voice: voice, prominent: false, onStart: captureVoiceDestination)
                            .disabled(!model.isConnected || liveState == nil || model.isLoadingConversation || voice.isBusy || !editorIsCurrent)
                        Button {
                            submit()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 30))
                        }
                        .disabled(!model.canSubmitConversation || model.isLoadingConversation || voice.isBusy)
                        .accessibilityLabel("Send to Pi")
                        .accessibilityIdentifier("central-pi-send")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(.bar)
    }

    private var draftBinding: Binding<String> {
        guard let editorBinding, let editorPresentationID else { return .constant("") }
        let target = editorBinding
        let presentationID = editorPresentationID
        return Binding(
            get: { model.conversationText(for: target, presentationID: presentationID) },
            set: { text in model.editConversation(text, presentationID: presentationID, binding: target) }
        )
    }

    private var liveState: CentralPiLiveState? {
        guard case .piObservation(.live(_, let state)) = model.conversationObservation?.payload else { return nil }
        return state
    }

    private var editorIsCurrent: Bool {
        guard let editorBinding, let editorPresentationID else { return false }
        return model.canEditConversation(presentationID: editorPresentationID, binding: editorBinding)
    }

    private func captureEditorBindingIfNeeded() {
        guard editorBinding == nil, let presentationID = model.conversationPresentationID,
              case .piObservation(.live(let binding, _)) = model.conversationObservation?.payload else { return }
        editorPresentationID = presentationID
        editorBinding = binding
    }

    private func captureVoiceDestination() -> Bool {
        guard editorIsCurrent, let editorBinding, let editorPresentationID, !voice.isBusy else { return false }
        do {
            voiceDestination = CentralVoiceDestination(
                capture: try model.conversationEditingCapture(presentationID: editorPresentationID, binding: editorBinding),
                presentationID: editorPresentationID,
                draft: model.conversationText(for: editorBinding, presentationID: editorPresentationID)
            )
            voiceNotice = nil
            unappliedTranscript = nil
            return true
        } catch {
            voiceNotice = "Voice capture requires the exact live Pi binding. No recording was started."
            return false
        }
    }

    private func receive(_ transcript: VoiceTranscript?) {
        guard let transcript, let destination = voiceDestination else { return }
        voiceDestination = nil
        do {
            guard try model.applyConversationEdit(
                transcript.appending(to: destination.draft),
                matching: destination.capture,
                presentationID: destination.presentationID
            ) else {
                model.abandonEmptyConversationCapture(destination.capture)
                unappliedTranscript = transcript.text
                voiceNotice = "Dictation was not applied or sent because its original binding or editing revision changed. Copy it only after confirming the destination."
                return
            }
            voiceNotice = nil
            unappliedTranscript = nil
            if transcript.delivery == .send {
                composerFocused = false
                submit(presentationID: destination.presentationID, binding: destination.capture.binding)
            }
        } catch {
            model.abandonEmptyConversationCapture(destination.capture)
            unappliedTranscript = transcript.text
            voiceNotice = "Dictation could not be applied to its captured editor. No request was sent."
        }
    }

    private func abandonVoiceDestination() {
        guard let destination = voiceDestination else { return }
        model.abandonEmptyConversationCapture(destination.capture)
        voiceDestination = nil
    }

    private func submit() {
        guard let editorPresentationID, let editorBinding, editorIsCurrent else { return }
        submit(presentationID: editorPresentationID, binding: editorBinding)
    }

    private func submit(presentationID: UUID, binding: CentralPiBindingTarget) {
        composerFocused = false
        Task { await model.submitConversation(presentationID: presentationID, binding: binding) }
    }
}

private struct CentralHistoryEntryRow: View {
    let entry: CentralPiCanonicalProjection

    var body: some View {
        if !entry.text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.role?.capitalized ?? entry.kind.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(entry.role == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .accessibilityElement(children: .combine)
        }
    }
}
