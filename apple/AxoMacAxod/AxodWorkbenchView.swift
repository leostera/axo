import AxoProtocol
import SwiftUI

struct AxodWorkbenchView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    @AppStorage private var sidebarCollapsed: Bool

    init(coordinator: AxodWorkbenchCoordinator) {
        self.coordinator = coordinator
        _sidebarCollapsed = AppStorage(wrappedValue: false, AxodSidebarPreferences.collapsedPreferenceKey,
            store: coordinator.preferences)
    }

    private let paneBackground = Color(red: 0.16, green: 0.17, blue: 0.19)

    var body: some View {
        VStack(spacing: 0) {
            if let message = coordinator.chatDrafts.quitMessage {
                AxodStatusNotice("Changes couldn’t be saved", details: message) { EmptyView() }
            }
            recoveryNotices
            AxodNativeWorkbenchSplitView(
                workbench: coordinator,
                workspaces: coordinator.workspaces,
                sessions: coordinator.sessions,
                selectedWorkspaceID: coordinator.selectedWorkspaceID,
                selectedSessionID: coordinator.selectedSessionID,
                sidebarCollapsed: $sidebarCollapsed,
                detail: AnyView(detailSurface)
            )
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear(perform: updateWindowTitle)
        .onChange(of: coordinator.selectedSessionID) { _, _ in updateWindowTitle() }
        .onChange(of: coordinator.sessions) { _, _ in updateWindowTitle() }
        .sheet(item: $coordinator.workEditor) { context in
            AxodWorkEditor(context: context, coordinator: coordinator).id(context.id)
        }
    }

    // Only actionable failures/unknown outcomes occupy chrome. Healthy work is
    // the sidebar and terminal tree, without connection or conversation controls.
    private var recoveryNotices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if connectionNeedsRecovery {
                AxodStatusNotice("Disconnected", details: coordinator.message) {
                    Button("Reconnect") { coordinator.connect() }
                }
            }
            if coordinator.pendingWorkCommandID != nil && !coordinator.isEditingWork {
                AxodStatusNotice("Change unconfirmed", details: coordinator.message) {
                    Button("Check Status") { coordinator.reconcilePendingWork() }
                        .disabled(coordinator.connectionState != .connected)
                }
            }
            if coordinator.pendingPiStartCommandID != nil && !coordinator.isStartingPi {
                AxodStatusNotice("Start unconfirmed", details: "Pi admission outcome is unknown; checking reconciles the original command without starting it again.") {
                    Button("Check Status") { coordinator.reconcilePendingPiStart() }
                        .disabled(coordinator.connectionState != .connected || coordinator.isReconcilingPiCommand)
                }
            }
            if coordinator.needsLoginItemsReview || coordinator.needsDaemonServiceReview {
                AxodStatusNotice(coordinator.needsLoginItemsReview || coordinator.serviceLifecycle.registration == .requiresApproval
                    ? "Approval needed" : "Background service unavailable", details: coordinator.serviceReviewMessage) {
                    Button("Settings…") { coordinator.showServiceSettingsWindow() }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var detailSurface: some View {
        ZStack(alignment: .topLeading) {
            paneBackground
            if let session = selectedSession {
                VStack(spacing: 0) {
                    AxodSessionTerminals(session: session, coordinator: coordinator).id(session.sessionId)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(coordinator.connectionState == .connected ? "Select or create a session" : "Background service unavailable")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                    if coordinator.connectionState == .connected, coordinator.emptyStartupMessage == nil {
                        Text("Press ⌘T to create a session.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.58))
                    } else {
                        DisclosureGroup("Details") {
                            Text(emptyDetailMessage).textSelection(.enabled)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.58))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var connectionNeedsRecovery: Bool {
        switch coordinator.connectionState {
        case .failed, .disconnected: true
        case .starting, .connected: false
        }
    }

    private var selectedSession: WorkSessionRecord? {
        coordinator.sessions.first { $0.sessionId == coordinator.selectedSessionID }
    }

    private var emptyDetailMessage: String {
        if coordinator.connectionState != .connected { return coordinator.message }
        if let startup = coordinator.emptyStartupMessage { return startup }
        return "Press ⌘T to create a session."
    }

    private func updateWindowTitle() {
        let base = "dev.leostera.axo.mac"
        let identifier = Bundle.main.bundleIdentifier ?? base
        let name = identifier.hasPrefix(base + ".")
            ? "Axo (\(identifier.dropFirst(base.count + 1)))"
            : "Axo"
#if DEBUG
        let titleName = CommandLine.arguments.contains("-ui-test") ? "Axo UI Test (temporary)" : name
#else
        let titleName = name
#endif
        let title = selectedSession.map { titleName + " — " + $0.displayName } ?? titleName
        let windowIdentifier = "Axo.MainWindow.\(Bundle.main.bundleIdentifier ?? "default")"
        NSApp.windows.first { $0.identifier?.rawValue == windowIdentifier }?.title = title
    }
}

extension TerminalProcess {
    var axodStatusTitle: String {
        switch self {
        case .starting: "Starting…"
        case .running: "Connecting…"
        case .stopping: "Stopping…"
        case .exited: "Session ended"
        case .failed: "Session unavailable"
        case .recoveryRequired: "Session needs recovery"
        }
    }

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
