 import AxoCore
import AxoVoice
import AVFoundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ConversationView: View {
    @State private var client = ConversationClient()
    @State private var voice = VoicePromptFactory.make()
    @AppStorage("relayEndpoint") private var endpointText = RelayEndpoint.defaultOrigin
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @State private var draft = ""
    @State private var submittedDraft: SubmittedPrompt?
    private struct SubmittedPrompt {
        let id: String
        let text: String
        let attachmentIDs: [String]
    }
    @State private var importingFile = false
    @State private var cameraDestination: CameraDestination?
    private struct CameraDestination: Identifiable {
        let id = UUID()
        let client: SessionFilesClient
        let session: String
    }
    @State private var selectingPhoto = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isPreparingPhotos = false
    @State private var publication: FilePublication?
    #if DEBUG
    @State private var previewFileClient: SessionFilesClient?
    #endif

    private var fileClient: SessionFilesClient? {
        #if DEBUG
        if SharedFilePreview.enabled { return previewFileClient }
        #endif
        return client.files
    }

    private struct FilePublication {
        let client: SessionFilesClient
        let draftIDs: [UUID]
    }
    @State private var pendingVoiceSendID: UUID?
    @State private var sheet: ChatSheet?
    @State private var error: String?
    @State private var scrollState = ConversationScrollState()
    @State private var scrollMetrics: ScrollMetrics?
    @State private var queuedEarlierDemand = false
    #if DEBUG
    @State private var previewNewMessages: [ConversationMessage] = []
    #endif
    private var followsLatest: Bool { scrollState.followsLatest }
    private var latestMessageID: String? {
        isPreview ? messages.last?.id : client.snapshot?.messages.last?.id
    }
    @State private var scrollRequest = 0
    @State private var scrollAnchor: String?
    @State private var userIsScrolling = false

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let contentHeight: CGFloat
        let nearTop: Bool
        let nearBottom: Bool
    }
    @State private var composerFocused = false
    @Environment(\.scenePhase) private var scenePhase

    private enum ChatSheet: String, Identifiable {
        case connection, login, voiceDetails, files
        var id: String { rawValue }
    }

    private func beginCameraCapture() {
        guard !voice.isBusy else { return }
        guard let destination = fileClient, let session = destination.sessionId else { sheet = .connection; return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            error = "Camera unavailable on this device. Choose Photos or Files instead."
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                error = "Camera access is disabled. Allow it in iOS Settings to take a photo."
                return
            }
            guard !voice.isBusy, fileClient === destination, destination.sessionId == session else { return }
            cameraDestination = CameraDestination(client: destination, session: session)
        }
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
        if SharedFilePreview.isInlinePhotoPreview {
            var rows = ChatPreviewData.messages
            if !rows.isEmpty { rows[0].attachments = previewFileClient?.readyDrafts }
            return rows
        }
        if isPreview { return ChatPreviewData.messages + previewNewMessages }
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
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(fileClient?.readyDrafts.isEmpty ?? true))
            && (fileClient?.canSubmitDrafts ?? true) && draft.utf16.count <= 16_000
    }

    var body: some View {
        conversation
            .background(ChatColors.background)
            .preferredColorScheme(appearance.colorScheme)
            .task {
                #if DEBUG
                if SharedFilePreview.enabled {
                    do { previewFileClient = try await SharedFilePreview.makeClient() }
                    catch { self.error = error.localizedDescription }
                }
                #endif
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(item: $sheet) { presented in
                switch presented {
                case .connection:
                    ConnectionSettingsView(endpoint: $endpointText, status: status, canConnect: !voice.isBusy,
                                           reconnect: { reconnect() }, signIn: signIn)
                case .login: login
                case .voiceDetails: VoiceInformationView()
                case .files:
                    if let files = fileClient { SessionFilesView(client: files) }
                    else { Text("Sign in to view session files.").padding() }
                }
            }
            .fullScreenCover(item: $cameraDestination) { destination in
                CameraCaptureView(captured: { image in
                    cameraDestination = nil
                    isPreparingPhotos = true
                    Task {
                        defer { isPreparingPhotos = false }
                        do {
                            let photo = try PickedPhoto.stageCameraImage(image)
                            defer { try? FileManager.default.removeItem(at: photo.url) }
                            try await PhotoPublication.addSelectedPhoto(photo.url, to: destination.client) {
                                fileClient === destination.client && destination.client.sessionId == destination.session
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                }, cancelled: { cameraDestination = nil })
                    .ignoresSafeArea()
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { if let files = fileClient { await stageFiles(urls, using: files) } }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .photosPicker(isPresented: $selectingPhoto, selection: $selectedPhotos, maxSelectionCount: max(1, 8 - (fileClient?.currentDrafts.count ?? 0)), matching: .images)
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty, let destination = fileClient else { return }
                selectedPhotos = []
                let session = destination.sessionId
                isPreparingPhotos = true
                Task {
                    defer { isPreparingPhotos = false }
                    for item in items {
                        do {
                            guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else { continue }
                            defer { try? FileManager.default.removeItem(at: photo.url) }
                            guard fileClient === destination, destination.sessionId == session else {
                                self.error = "Photo destination changed. Select the photos again in the intended conversation."
                                return
                            }
                            try await PhotoPublication.addSelectedPhoto(photo.url, to: destination) {
                                fileClient === destination && destination.sessionId == session
                            }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .confirmationDialog("Upload to private cloud?", isPresented: Binding(get: { publication != nil }, set: { if !$0 { publication = nil } }), titleVisibility: .visible) {
                Button("Upload files") {
                    if let publication { for id in publication.draftIDs { publication.client.retryUpload(id) } }
                    publication = nil
                }
                Button("Keep drafts without uploading") { publication = nil }
            } message: {
                Text("Selected snapshots are readable by Cloudflare and the relay; this is not end-to-end encrypted. Share only non-sensitive, approved files. Uploading does not send a prompt.\nDestination: \(publication?.client.storageOrigin.absoluteString ?? "relay")")
            }
            .onChange(of: endpointText) { _, _ in error = nil; client.disconnect() }
            .onChange(of: client.lastAcknowledgedID) { _, id in
                if let sent = submittedDraft, id == sent.id {
                    if draft == sent.text { draft = "" }
                    fileClient?.acknowledgeDrafts(ids: sent.attachmentIDs)
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
                    pendingVoiceSendID = transcript.delivery == .send ? transcript.id : nil
                    sendVoiceTranscriptIfReady()
                }
            }
            .onChange(of: voice.state) { _, state in
                if state == .ready { sendVoiceTranscriptIfReady() }
                if state == .idle || state == .cancelling { pendingVoiceSendID = nil }
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
                        if client.isLoadingHistory {
                            ProgressView("Loading earlier messages…").font(.caption)
                        } else {
                            Button("Load earlier messages") { client.loadEarlierMessages() }
                                .font(.caption).foregroundStyle(.secondary)
                                .disabled(client.link != .online)
                        }
                    }
                    ForEach(messages) { message in
                        ChatMessageView(message: message, activity: agentActivities.first { $0.id == message.toolCallId },
                                        outputState: message.toolCallId.flatMap { client.toolOutputs[$0] },
                                        loadOutput: { if let id = message.toolCallId { client.loadToolOutput(toolCallId: id) } }, fileClient: fileClient)
                    }
                    ForEach(client.pendingPrompts) { message in
                        ChatMessageView(message: message, fileClient: fileClient, isPending: true)
                    }
                    AgentActivityView(state: agentState, runId: agentRunId, activities: agentActivities,
                                       canCancel: canCancelAgent,
                                       isCancelling: client.pendingCancellationID != nil,
                                       cancelRun: { client.cancelAgent(runId: $0) })
                    if client.hasLaterMessages {
                        Button("Load newer messages") { client.loadLaterMessages() }
                            .font(.caption).foregroundStyle(.secondary)
                            .disabled(client.isLoadingHistory || client.link != .online)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition(id: $scrollAnchor, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if phase == .idle, followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let bottom = max(0, geometry.contentSize.height + geometry.contentInsets.top
                                 + geometry.contentInsets.bottom - geometry.containerSize.height)
                return ScrollMetrics(offset: offset, contentHeight: geometry.contentSize.height,
                                     nearTop: offset < geometry.containerSize.height / 2,
                                     nearBottom: offset >= bottom - 60)
            } action: { old, new in
                scrollMetrics = new
                // Streaming/layout growth must not switch off follow-latest.
                if followsLatest && !userIsScrolling && (old.contentHeight != new.contentHeight || !new.nearBottom) {
                    proxy.scrollTo("latest", anchor: .bottom)
                }
                // Page insertion/reconnect are not user demand. The bound anchor
                // keeps the same message visible as older rows are prepended.
                guard userIsScrolling, old.contentHeight == new.contentHeight, old.offset != new.offset else { return }
                scrollState.userScrolled(isAtLatest: new.nearBottom && !client.hasLaterMessages)
                client.isBrowsingHistory = !followsLatest
                if new.offset < old.offset && new.nearTop {
                    if client.isLoadingHistory { queuedEarlierDemand = true }
                    else { client.loadEarlierMessages() }
                }
                if new.offset > old.offset && new.nearBottom { client.loadLaterMessages() }
            }
            .onChange(of: client.isLoadingHistory) { _, loading in
                guard !loading, queuedEarlierDemand else { return }
                queuedEarlierDemand = false
                // Consume at most one queued, user-generated demand. Never
                // recurse through every historical page just because it exists.
                if !followsLatest, scrollMetrics?.nearTop == true { client.loadEarlierMessages() }
            }
            .onChange(of: latestMessageID) { previous, next in
                scrollState.latestMessageChanged(from: previous, to: next)
            }
            .onChange(of: client.snapshot?.viewId) { previous, next in
                if let previous, let next, previous != next {
                    scrollState.jumpToLatest()
                    queuedEarlierDemand = false
                }
            }
            .onChange(of: messages) { _, _ in
                if followsLatest && !userIsScrolling { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: client.pendingPrompts) { _, _ in
                if followsLatest && !userIsScrolling { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: agentActivities) { _, _ in
                if followsLatest && !userIsScrolling { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: scrollRequest) { _, _ in
                withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        ZStack {
            headerTitle
            HStack(spacing: 16) {
                Button { composerFocused = false; sheet = .connection } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 21, weight: .medium))
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(ChatColors.border, lineWidth: 0.5))
                }.accessibilityLabel("Connection settings").disabled(voice.isBusy)
                Spacer(minLength: 0)
                headerActions
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 10)
        .background(ChatColors.background.opacity(0.96))
    }

    private var headerActions: some View {
        HStack(spacing: 0) {
            Button { composerFocused = true } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 21)).frame(width: 45, height: 46)
            }.accessibilityLabel("Write a message")
            Menu {
                Button("Connection settings", systemImage: "network") { sheet = .connection }.disabled(voice.isBusy)
                Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }.disabled(voice.isBusy)
                Button("Session files", systemImage: "folder") { sheet = .files }
                Button("About voice", systemImage: "waveform") { sheet = .voiceDetails }.disabled(voice.isBusy)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--axo-live-history-preview") {
                    Button("Add synthetic message") {
                        if let message = ChatPreviewData.newMessage() { previewNewMessages.append(message) }
                    }
                }
                #endif
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold)).frame(width: 44, height: 46)
            }.accessibilityLabel("Chat options")
        }
        .padding(.horizontal, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(ChatColors.border, lineWidth: 0.5))
    }

    private var headerTitle: some View {
        Button { sheet = .connection } label: {
            VStack(spacing: 3) {
                Text("Axo").font(.headline).accessibilityIdentifier("conversation-title")
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(shortStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("Axo. \(status)")
        .disabled(voice.isBusy)
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
            if !followsLatest || client.hasLaterMessages {
                Button {
                    if isPreview || client.backToBottom() {
                        scrollState.jumpToLatest()
                        queuedEarlierDemand = false
                        scrollRequest += 1
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        if scrollState.hasNewMessages { Text("Jump to new message").font(.callout.weight(.semibold)).padding(.trailing, 14) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .accessibilityLabel(scrollState.hasNewMessages ? "Jump to new message" : "Jump to latest")
                .accessibilityIdentifier("back-to-bottom")
            }
            if isPreparingPhotos { ProgressView("Preparing attachments…").font(.caption) }
            if let notice = fileClient?.notice { Text(notice).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24) }
            ChatComposer(draft: $draft, focused: $composerFocused, voice: voice, canSend: canSend,
                         send: send,
                         hasAttachments: !(fileClient?.currentDrafts.isEmpty ?? true),
                         attachFile: { if fileClient != nil { importingFile = true } else { sheet = .connection } },
                         attachPhoto: { if fileClient != nil { selectingPhoto = true } else { sheet = .connection } },
                         attachCamera: { Task { @MainActor in beginCameraCapture() } },
                         fileClient: fileClient, canAttachPhotos: !isPreparingPhotos && (fileClient?.currentDrafts.count ?? 0) < 8,
                         reviewUpload: { id in if let files = fileClient { publication = FilePublication(client: files, draftIDs: [id]) } },
                         pasteAttachments: pasteAttachments)
        }
        .padding(.top, 10).padding(.bottom, 8)
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

    private func pasteAttachments(_ providers: [NSItemProvider]) {
        guard !voice.isBusy, !isPreparingPhotos else { error = "Finish the current capture before pasting attachments."; return }
        guard let destination = fileClient, let session = destination.sessionId else {
            error = "Connect to a conversation before pasting attachments. Your clipboard is unchanged."
            return
        }
        guard providers.count <= 8 - destination.currentDrafts.count else {
            error = "A prompt can have at most 8 attachments. Your clipboard is unchanged."
            return
        }
        isPreparingPhotos = true
        Task {
            defer { isPreparingPhotos = false }
            var documents: [UUID] = []
            for provider in providers {
                do {
                    let attachment = try await ClipboardAttachment.load(provider)
                    defer { attachment.discardTemporaryCopy() }
                    guard fileClient === destination, destination.sessionId == session else {
                        error = "Paste destination changed. Paste again in the intended conversation."
                        return
                    }
                    switch attachment.kind {
                    case .photo:
                        let photo = try PickedPhoto.stageFile(attachment.source)
                        defer { try? FileManager.default.removeItem(at: photo.url) }
                        try await PhotoPublication.addSelectedPhoto(photo.url, to: destination) {
                            fileClient === destination && destination.sessionId == session
                        }
                    case .file:
                        if let id = await destination.addFile(attachment.source) { documents.append(id) }
                    }
                } catch { self.error = error.localizedDescription }
            }
            if !documents.isEmpty {
                guard fileClient === destination, destination.sessionId == session else {
                    error = "Pasted files remain local drafts in their original conversation. Review them there before uploading."
                    return
                }
                publication = FilePublication(client: destination, draftIDs: documents)
            }
        }
    }

    private func stageFiles(_ urls: [URL], using files: SessionFilesClient) async {
        var ids: [UUID] = []
        for url in urls { if let id = await files.addFile(url) { ids.append(id) } }
        if !ids.isEmpty { publication = FilePublication(client: files, draftIDs: ids) }
    }

    private func send() {
        guard canSend, let session = client.snapshot?.sessionId else { return }
        let id = UUID().uuidString
        let attachments = fileClient?.readyDrafts.map(\.id) ?? []
        submittedDraft = SubmittedPrompt(id: id, text: draft, attachmentIDs: attachments)
        _ = client.backToBottom()
        scrollState.jumpToLatest()
        queuedEarlierDemand = false
        scrollRequest += 1
        client.send(.prompt(id: id, session: session, text: draft, attachmentIds: attachments))
    }

    private func answer(_ question: Question, _ value: String) {
        guard client.canSend, let session = client.snapshot?.sessionId else { return }
        client.send(.answer(id: UUID().uuidString, session: session, question: question.id, value: value))
    }
}
