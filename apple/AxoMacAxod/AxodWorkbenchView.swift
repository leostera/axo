import AxoProtocol
import SwiftUI

struct AxodWorkbenchView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    @AppStorage("Axo.axod.sidebarCollapsed") private var sidebarCollapsed = false
    @State private var showingSettings = false
    @State private var showingUnavailableAction = false

    private let paneBackground = Color(red: 0.16, green: 0.17, blue: 0.19)

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if sidebarCollapsed {
                    Button {
                        sidebarCollapsed = false
                    } label: {
                        Image(systemName: "sidebar.left")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .help("Show sidebar")
                } else {
                    sidebar
                        .frame(minWidth: 180, idealWidth: 300, maxWidth: 300)
                }

                detailSurface
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            statusBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear(perform: updateWindowTitle)
        .onChange(of: coordinator.selectedSessionID) { _, _ in updateWindowTitle() }
        .onChange(of: coordinator.sessions) { _, _ in updateWindowTitle() }
        .alert("Not available in this build", isPresented: $showingUnavailableAction) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This Axod-only build reads daemon work records but does not yet create workspaces or sessions.")
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Axo")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingUnavailableAction = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Create workspace or session")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeading("Workspaces")
                        .padding(.top, 12)

                    ForEach(coordinator.workspaces, id: \.workspaceId) { workspace in
                        sidebarRow(
                            workspace.name,
                            systemImage: "folder",
                            selected: coordinator.selectedWorkspaceID == workspace.workspaceId && coordinator.selectedSessionID == nil
                        ) {
                            coordinator.selectWorkspace(workspace.workspaceId)
                        }

                        if coordinator.selectedWorkspaceID == workspace.workspaceId {
                            sectionHeading("Sessions")
                                .padding(.top, 8)
                                .padding(.leading, 14)

                            ForEach(coordinator.sessions, id: \.sessionId) { session in
                                sidebarRow(
                                    session.name,
                                    systemImage: statusSymbol(session.runtime?.process),
                                    symbolColor: statusColor(session.runtime?.process),
                                    selected: coordinator.selectedSessionID == session.sessionId,
                                    indentation: 18
                                ) {
                                    coordinator.selectSession(session.sessionId)
                                }
                            }

                            if coordinator.sessions.isEmpty && coordinator.connectionState == .connected {
                                Text("No sessions")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 38)
                                    .padding(.vertical, 5)
                            }

                            if coordinator.nextSessionCursor != nil {
                                Button("Load more sessions") { coordinator.loadMoreSessions() }
                                    .font(.system(size: 12))
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 38)
                                    .padding(.vertical, 5)
                            }
                        }
                    }

                    if coordinator.nextWorkspaceCursor != nil {
                        Button("Load more workspaces") { coordinator.loadMoreWorkspaces() }
                            .font(.system(size: 12))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 18)
                            .padding(.vertical, 5)
                    }

                    if coordinator.workspaces.isEmpty && coordinator.connectionState == .connected {
                        Text("No workspaces")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 18)
                            .padding(.vertical, 5)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .padding(.horizontal, 12)

            HStack {
                Button("Settings") { showingSettings = true }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    sidebarCollapsed = true
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Collapse sidebar")
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var detailSurface: some View {
        ZStack(alignment: .topLeading) {
            paneBackground

            if let session = selectedSession {
                VStack(alignment: .leading, spacing: 7) {
                    Text(session.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
                    Text("Axod work record · Pi admission: \(session.pi.admission.rawValue)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.58))
                    if let runtime = session.runtime {
                        Text("Runtime: \(runtime.process.axodDescription) · \(runtime.backlogBytes) bytes buffered")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.58))
                    } else {
                        Text("No runtime record")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.58))
                    }
                    Spacer(minLength: 20)
                    Text("Terminal attachment is not available in this build.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
                .padding(12)
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

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(coordinator.message)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if coordinator.needsLoginItemsReview {
                Button("Review Login Items…") { coordinator.openLoginItemsSettings() }
                    .buttonStyle(.plain)
            }
            if coordinator.connectionState == .connected {
                Button("Refresh") { coordinator.refresh() }
                    .buttonStyle(.plain)
            } else {
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

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Divider()
            Text("Startup")
                .font(.headline)
            Text(coordinator.startupMessage)
                .foregroundStyle(.secondary)
            if coordinator.needsLoginItemsReview {
                Button("Review Login Items…") { coordinator.openLoginItemsSettings() }
            }
            Text("Axo opens at user login and starts the bundled axod daemon. The daemon is not installed as a separate system service.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Text("Local daemon")
                .font(.headline)
            Text("Axo reads workspace, session, and runtime metadata only. Pi chat history and terminal attachment are not available in this build.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { showingSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 360)
    }

    private var selectedSession: WorkSessionRecord? {
        coordinator.sessions.first { $0.sessionId == coordinator.selectedSessionID }
    }

    private var emptyDetailMessage: String {
        if coordinator.connectionState != .connected { return coordinator.message }
        if coordinator.workspaces.isEmpty {
            return "No legacy workspace data was imported. Workspaces appear here when owned by the local daemon."
        }
        return "This workspace has no session records. Selecting records never starts a runtime."
    }

    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .starting: .orange
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private func updateWindowTitle() {
        let title = selectedSession.map { "Axo — " + $0.name } ?? "Axo"
        NSApp.keyWindow?.title = title
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func sidebarRow(
        _ title: String,
        systemImage: String,
        symbolColor: Color = .secondary,
        selected: Bool,
        indentation: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? Color.white : symbolColor)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 2 + indentation)
            .padding(.trailing, 6)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusSymbol(_ process: TerminalProcess?) -> String {
        switch process {
        case .starting: "circle.dotted"
        case .running: "circle.fill"
        case .stopping: "circle.dashed"
        case .exited, .failed, .recoveryRequired, nil: "circle"
        }
    }

    private func statusColor(_ process: TerminalProcess?) -> Color {
        switch process {
        case .starting, .stopping: .orange
        case .running: .green
        case .exited, .failed, .recoveryRequired, nil: .secondary
        }
    }
}

private extension TerminalProcess {
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
