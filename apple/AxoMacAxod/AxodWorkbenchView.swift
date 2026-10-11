import AxoProtocol
import SwiftUI

struct AxodWorkbenchView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    @AppStorage(AxodSidebarToolbar.collapsedPreferenceKey) private var sidebarCollapsed = false
    @State private var showsConversation = false

    private let paneBackground = Color(red: 0.16, green: 0.17, blue: 0.19)

    var body: some View {
        VStack(spacing: 0) {
            AxodNativeWorkbenchSplitView(
                workbench: coordinator,
                workspaces: coordinator.workspaces,
                sessions: coordinator.sessions,
                selectedWorkspaceID: coordinator.selectedWorkspaceID,
                selectedSessionID: coordinator.selectedSessionID,
                sidebarCollapsed: $sidebarCollapsed,
                detail: AnyView(detailSurface),
                openSettings: { coordinator.showSettingsWindow() },
                createWork: { coordinator.showCreationMenu() }
            )
            statusBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear(perform: updateWindowTitle)
        .onChange(of: coordinator.selectedSessionID) { _, _ in updateWindowTitle() }
        .onChange(of: coordinator.sessions) { _, _ in updateWindowTitle() }
        .sheet(item: $coordinator.workEditor) { context in
            AxodWorkEditor(context: context, coordinator: coordinator).id(context.id)
        }
    }

    private var detailSurface: some View {
        ZStack(alignment: .topLeading) {
            paneBackground
            if let session = selectedSession {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.9))
                            Text("Axod work record · Pi admission: \(session.pi.admission.rawValue)")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.58))
                            if let runtime = session.runtime {
                                Text("Runtime: \(runtime.process.axodDescription) · \(runtime.backlogBytes) bytes buffered")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.white.opacity(0.58))
                            }
                        }
                        Spacer()
                        Button(showsConversation ? "Terminals" : "Conversation") { showsConversation.toggle() }
                        if let title = piStartActionTitle(for: session) {
                            Button {
                                if coordinator.pendingPiStartCommandID == nil {
                                    coordinator.startOrResumePi()
                                } else {
                                    coordinator.reconcilePendingPiStart()
                                }
                            } label: {
                                if coordinator.isStartingPi || coordinator.isReconcilingPiCommand {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(coordinator.pendingPiStartCommandID == nil ? title : "Reconcile start")
                                }
                            }
                            .disabled(coordinator.connectionState != .connected || coordinator.isStartingPi || coordinator.isReconcilingPiCommand)
                        } else if coordinator.pendingPiStartCommandID != nil {
                            Button("Reconcile start") { coordinator.reconcilePendingPiStart() }
                                .disabled(coordinator.connectionState != .connected || coordinator.isReconcilingPiCommand)
                        }
                    }
                    .padding(12)
                    Divider().overlay(Color.white.opacity(0.08))
                    if showsConversation {
                        chatContent
                    } else {
                        AxodSessionTerminals(session: session, coordinator: coordinator).id(session.sessionId)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(coordinator.selectedWorkspaceID == nil ? "Axo" : "No sessions yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Text(emptyDetailMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(coordinator.chatStatusMessage)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if coordinator.pendingChatCommandId != nil {
                    Button("Reconcile command") { coordinator.reconcilePendingPiCommand() }
                        .disabled(coordinator.isReconcilingPiCommand || coordinator.connectionState != .connected)
                } else if coordinator.chatTarget != nil {
                    Button("Refresh chat") { coordinator.refreshChat() }
                        .disabled(coordinator.connectionState != .connected)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.62))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if let snapshot = coordinator.chatSnapshot {
                if coordinator.nextChatCursor != nil {
                    Button("Load earlier history") { coordinator.loadMoreChatHistory() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.white.opacity(0.66))
                        .padding(.vertical, 5)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(coordinator.chatEntries, id: \.entryId) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.role ?? entry.toolName ?? entry.kind.capitalized)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                Text(entry.text.isEmpty ? "[No text content]" : entry.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.88))
                                    .textSelection(.enabled)
                                if entry.truncated {
                                    Text("Entry truncated by Axod's bounded history projection.")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.orange.opacity(0.78))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(12)
                }
                if let question = snapshot.question {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(question.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                        HStack {
                            ForEach(question.options, id: \.id) { option in
                                Button(option.label) { coordinator.answerChatQuestion(question, option: option, snapshot: snapshot) }
                                    .disabled(snapshot.readMode != .live || coordinator.pendingChatCommandId != nil || coordinator.isSendingPiMessage)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.045))
                }
                if snapshot.readMode == .live {
                    AxodChatComposer(snapshot: snapshot, coordinator: coordinator, drafts: coordinator.chatDrafts)
                } else {
                    Text("Pi is stopped; this canonical conversation is read-only.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else if coordinator.chatTarget == nil {
                VStack(alignment: .leading, spacing: 8) {
                    if sessionRequiresRecovery {
                        Text("No process, conversation, or historic PID is adopted automatically.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else {
                ProgressView("Loading canonical Pi history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func piStartActionTitle(for session: WorkSessionRecord) -> String? {
        switch session.pi.admission {
        case .notAdmitted: return "Start Pi"
        case .stopped, .failed: return "Resume Pi"
        case .ready, .recoveryRequired: return nil
        }
    }

    private var sessionRequiresRecovery: Bool {
        selectedSession?.pi.admission == .recoveryRequired
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            if coordinator.pendingWorkCommandID != nil {
                Button("Reconcile work command") { coordinator.reconcilePendingWork() }
                    .disabled(coordinator.connectionState != .connected || coordinator.isEditingWork)
            }
            Text(coordinator.onlineMessage)
                .help(coordinator.message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if coordinator.needsLoginItemsReview || coordinator.needsDaemonServiceReview {
                Button("Review Login Items…") { coordinator.openLoginItemsSettings() }
                    .buttonStyle(.plain)
            }
            if coordinator.connectionState != .connected {
                Button("Connect") { coordinator.connect() }
                    .buttonStyle(.plain)
                    .disabled(coordinator.connectionState == .starting)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedSession: WorkSessionRecord? {
        coordinator.sessions.first { $0.sessionId == coordinator.selectedSessionID }
    }

    private var emptyDetailMessage: String {
        if coordinator.connectionState != .connected { return coordinator.message }
        if let startup = coordinator.emptyStartupMessage { return startup }
        if coordinator.workspaces.isEmpty {
            return "No legacy workspace data was imported. Workspaces appear here when owned by the local daemon."
        }
        return "This workspace has no session records. Selecting records never starts a runtime."
    }

    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .starting: .yellow
        case .connected: coordinator.hostStatus?.cloud.isOnline == true ? .green : .blue
        case .disconnected: .red
        case .failed: .red
        }
    }

    private func updateWindowTitle() {
        let base = "dev.leostera.axo.mac"
        let identifier = Bundle.main.bundleIdentifier ?? base
        let name = identifier.hasPrefix(base + ".")
            ? "Axo (\(identifier.dropFirst(base.count + 1)))"
            : "Axo"
        let title = selectedSession.map { name + " — " + $0.displayName } ?? name
        let windowIdentifier = "Axo.MainWindow.\(Bundle.main.bundleIdentifier ?? "default")"
        NSApp.windows.first { $0.identifier?.rawValue == windowIdentifier }?.title = title
    }

}

extension TerminalProcess {
    var axodDescription: String {
        switch self {
        case .starting: "Starting"
        case .running(let pid): "Running · pid \(pid)"
        case .stopping(let pid): "Stopping · pid \(pid)"
        case .exited(let status): "Exited · status \(status)"
        case .failed: "Failed"
        case .recoveryRequired: "Recovery required"
        }
    }
}
