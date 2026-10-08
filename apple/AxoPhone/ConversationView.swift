import AxoCore
import AxoVoice
import SwiftUI

struct ConversationView: View {
    @State private var client = ConversationClient()
    @State private var voice = VoicePrompt(recorder: MicrophoneRecorder(), transcriber: AppleSpeechProvider.makeTranscriber())
    @AppStorage("relayEndpoint") private var endpointText = RelayEndpoint.defaultOrigin
    @State private var draft = ""
    @State private var submittedDraft: (id: String, text: String)?
    @State private var pendingVoiceSendID: UUID?
    @State private var sheet: ChatSheet?
    @State private var error: String?
    @State private var followsLatest = true
    @State private var scrollRequest = 0
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private enum ChatSheet: String, Identifiable {
        case connection, login, voiceDetails
        var id: String { rawValue }
    }

    private var endpoint: RelayEndpoint? { try? RelayEndpoint(endpointText) }
    private var isPreview: Bool {
        #if DEBUG
        return ChatPreviewData.enabled
        #else
        return false
        #endif
    }
    private var messages: [ConversationMessage] {
        #if DEBUG
        if isPreview { return ChatPreviewData.messages }
        #endif
        return client.messages
    }
    private var agentState: AgentState? {
        #if DEBUG
        if ChatPreviewData.showsActivity { return .running }
        #endif
        return client.snapshot?.state
    }
    private var agentActivities: [AgentActivity] {
        #if DEBUG
        if ChatPreviewData.showsActivity { return ChatPreviewData.activities }
        #endif
        return client.snapshot?.activities ?? []
    }
    private var agentRunId: String? {
        #if DEBUG
        if ChatPreviewData.showsActivity { return "preview-run" }
        #endif
        return client.snapshot?.runId
    }
    private var canCancelAgent: Bool {
        #if DEBUG
        if ChatPreviewData.showsActivity { return true }
        #endif
        return client.canSend && agentRunId != nil
    }
    private var canSend: Bool {
        !voice.isBusy && client.canSend && client.snapshot?.question == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf16.count <= 16_000
    }

    var body: some View {
        conversation
            .background(Color.black)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(item: $sheet) { presented in
                switch presented {
                case .connection:
                    ConnectionSettingsView(endpoint: $endpointText, status: status, canConnect: !voice.isBusy,
                                           reconnect: { reconnect() }, signIn: signIn)
                case .login: login
                case .voiceDetails: VoiceInformationView()
                }
            }
            .onChange(of: endpointText) { _, _ in error = nil; client.disconnect() }
            .onChange(of: client.lastAcknowledgedID) { _, id in
                if let sent = submittedDraft, id == sent.id {
                    if draft == sent.text { draft = "" }
                    submittedDraft = nil
                }
            }
            .onChange(of: voice.transcript) { _, transcript in
                guard let transcript else { return }
                draft = transcript.appending(to: draft)
                if draft.utf16.count > 16_000 {
                    pendingVoiceSendID = nil
                    error = "Draft exceeds 16,000 characters. Trim it before sending; no dictated text was discarded."
                } else {
                    pendingVoiceSendID = transcript.id
                    sendVoiceTranscriptIfReady()
                }
            }
            .onChange(of: voice.state) { _, state in
                if state == .ready { sendVoiceTranscriptIfReady() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { client.disconnect(); voice.cancel() }
                if phase == .active, client.link == .disconnected, !voice.isBusy { reconnect(openLogin: false) }
            }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if messages.isEmpty {
                        ChatEmptyState(status: status, connect: { sheet = .connection }).disabled(voice.isBusy)
                    }
                    if client.hasEarlierMessages {
                        Button(client.isLoadingHistory ? "Loading earlier messages…" : "Load earlier messages") {
                            client.loadEarlierMessages()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .disabled(client.isLoadingHistory || client.link != .online)
                    }
                    ForEach(messages) { message in
                        ChatMessageView(message: message, activity: agentActivities.first { $0.id == message.toolCallId },
                                        outputState: message.toolCallId.flatMap { client.toolOutputs[$0] },
                                        loadOutput: { if let id = message.toolCallId { client.loadToolOutput(toolCallId: id) } })
                    }
                    AgentActivityView(state: agentState, runId: agentRunId, activities: agentActivities,
                                       canCancel: canCancelAgent,
                                       isCancelling: client.pendingCancellationID != nil,
                                       cancelRun: { client.cancelAgent(runId: $0) })
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followsLatest = true }
                        .onDisappear { followsLatest = false }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: agentActivities) { _, _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: scrollRequest) { _, _ in
                withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { composerFocused = false; sheet = .connection } label: {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 21, weight: .medium))
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.5))
            }.accessibilityLabel("Connection settings").disabled(voice.isBusy)
            Spacer(minLength: 0)
            Button { sheet = .connection } label: {
                VStack(spacing: 3) {
                    Text("Axo").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 5, height: 5)
                        Text(shortStatus).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.accessibilityLabel("Axo. \(status)").disabled(voice.isBusy)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { composerFocused = true } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 21))
                        .frame(width: 45, height: 46)
                }.accessibilityLabel("Write a message")
                Menu {
                    Button("Connection settings", systemImage: "network") { sheet = .connection }.disabled(voice.isBusy)
                    Button("Jump to latest", systemImage: "arrow.down") { scrollRequest += 1 }
                    Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }.disabled(voice.isBusy)
                    Button("About voice", systemImage: "waveform") { sheet = .voiceDetails }.disabled(voice.isBusy)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
                        .frame(width: 44, height: 46)
                }.accessibilityLabel("Chat options")
            }
            .padding(.horizontal, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
        .background(Color.black.opacity(0.96))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let question = client.snapshot?.question {
                ChatQuestionCard(question: question, canAnswer: client.canSend, answer: { answer(question, $0) })
                    .padding(.horizontal, 16)
            }
            if let error {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { self.error = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss error")
                }.padding(.horizontal, 24)
            }
            if let notice = client.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            }
            ChatComposer(draft: $draft, focused: $composerFocused, voice: voice, canSend: canSend,
                         send: send, connectionSettings: { sheet = .connection }, voiceDetails: { sheet = .voiceDetails })
        }
        .padding(.top, 10).padding(.bottom, 8)
        .background(Color.black)
    }

    @ViewBuilder private var login: some View {
        if let endpoint {
            NavigationStack {
                AccessLogin(endpoint: endpoint, onAuthenticated: { token in
                    do {
                        try AccessCredential.save(token, host: endpoint.baseURL.host!)
                        sheet = nil
                        client.connect(endpoint: endpoint, authorizationCookie: token)
                    } catch { self.error = "Could not save Access credentials securely." }
                }, onFailure: { error = $0 })
                .navigationTitle("Cloudflare Access").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    if let error { Text(error).foregroundStyle(.red).font(.caption).padding() }
                }
                .toolbar { Button("Cancel") { sheet = nil } }
            }
        }
    }

    private var shortStatus: String {
        if isPreview { return "Preview" }
        return switch client.link {
        case .disconnected, .failed: "Disconnected"
        case .connecting: "Connecting"
        case .macOffline: "Mac offline"
        case .online:
            switch client.snapshot?.state {
            case .running: "Pi is working"
            case .waiting: "Waiting for you"
            default: "Connected"
            }
        }
    }

    private var statusColor: Color {
        switch client.link {
        case .online: client.snapshot?.state == .waiting ? .orange : .green
        case .connecting: .orange
        default: .gray
        }
    }

    private var status: String {
        if isPreview { return "UI preview — no relay connection." }
        return switch client.link {
        case .disconnected: "Sign in to connect to your Mac."
        case .connecting: "Connecting to your relay…"
        case .macOffline: "Mac offline — prompts are not queued."
        case .failed(let message): message
        case .online: client.snapshot.map { "Pi: \($0.state.rawValue)" } ?? "Waiting for conversation…"
        }
    }

    private func signIn() {
        error = nil
        guard endpoint != nil else { error = "Enter an HTTPS origin, without a path."; return }
        sheet = .login
    }

    private func reconnect(openLogin: Bool = true) {
        guard !isPreview else { return }
        error = nil
        guard let endpoint else { error = "Enter a valid HTTPS endpoint."; return }
        guard let token = AccessCredential.load(host: endpoint.baseURL.host!) else {
            if openLogin { sheet = .login }
            return
        }
        sheet = nil
        client.connect(endpoint: endpoint, authorizationCookie: token)
    }

    private func sendVoiceTranscriptIfReady() {
        guard let pendingVoiceSendID,
              voice.transcript?.id == pendingVoiceSendID,
              voice.state == .ready else { return }
        self.pendingVoiceSendID = nil
        guard canSend else { return }
        send()
    }

    private func send() {
        guard canSend, let session = client.snapshot?.sessionId else { return }
        let id = UUID().uuidString
        submittedDraft = (id, draft)
        followsLatest = true
        client.send(.prompt(id: id, session: session, text: draft))
    }

    private func answer(_ question: Question, _ value: String) {
        guard client.canSend, let session = client.snapshot?.sessionId else { return }
        client.send(.answer(id: UUID().uuidString, session: session, question: question.id, value: value))
    }
}
