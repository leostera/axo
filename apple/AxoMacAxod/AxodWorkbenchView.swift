import AxoProtocol
import SwiftUI

struct AxodWorkbenchView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            TabView {
                workspaceBrowser
                    .tabItem { Label("Workspaces", systemImage: "folder") }
                runtimeBrowser
                    .tabItem { Label("Runtimes", systemImage: "server.rack") }
            }
            Text("Local loopback RPC is credential-free, not OS-user authorization. This app currently reads work and runtime metadata only.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var connectionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Axo · axod")
                    .font(.headline)
                Text(coordinator.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if coordinator.connectionState == .connected {
                Button("Refresh") { coordinator.refresh() }
                Button("Disconnect") { coordinator.disconnect() }
            } else {
                Button("Connect / Reconnect") { coordinator.connect() }
                    .disabled(coordinator.connectionState == .starting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var workspaceBrowser: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { coordinator.selectedWorkspaceID },
                set: { coordinator.selectWorkspace($0) }
            )) {
                ForEach(coordinator.workspaces, id: \.workspaceId) { workspace in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name)
                        Text(workspace.directoryId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(workspace.workspaceId))
                    .padding(.vertical, 3)
                }
                if coordinator.nextWorkspaceCursor != nil {
                    Button("Load more workspaces") { coordinator.loadMoreWorkspaces() }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("Workspaces")
            .overlay {
                if coordinator.connectionState == .connected && coordinator.workspaces.isEmpty {
                    ContentUnavailableView(
                        "No daemon workspaces",
                        systemImage: "folder",
                        description: Text("This Axod-only app uses a new daemon state directory. Legacy workspaces were not imported.")
                    )
                }
            }
        } detail: {
            sessionDetail
        }
        .tabItem { Label("Workspaces", systemImage: "folder") }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let workspaceID = coordinator.selectedWorkspaceID,
           let workspace = coordinator.workspaces.first(where: { $0.workspaceId == workspaceID }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.name).font(.title2.weight(.semibold))
                        Text("Directory profile: \(workspace.directoryId)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                List {
                    ForEach(coordinator.sessions, id: \.sessionId) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.name)
                                .font(.body.weight(.medium))
                            Text("Pi: \(session.pi.admission.rawValue) · pane \(session.pi.paneId.uuidString.lowercased())")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            if let runtime = session.runtime {
                                Text(runtime.process.axodDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if coordinator.nextSessionCursor != nil {
                        Button("Load more sessions") { coordinator.loadMoreSessions() }
                            .buttonStyle(.plain)
                    }
                }
                .overlay {
                    if coordinator.sessions.isEmpty && coordinator.nextSessionCursor == nil {
                        ContentUnavailableView(
                            "No sessions in this workspace",
                            systemImage: "rectangle.stack",
                            description: Text("Reading work records does not create a Pi chat or launch a process.")
                        )
                    }
                }
            }
            .navigationTitle(workspace.name)
        } else {
            ContentUnavailableView(
                "Select a workspace",
                systemImage: "folder",
                description: Text("Axo reads the local daemon's work records. No legacy registry or Pi history is imported.")
            )
        }
    }

    private var runtimeBrowser: some View {
        List {
            ForEach(coordinator.runtimes, id: \.runtime.runtimeGeneration) { terminal in
                VStack(alignment: .leading, spacing: 5) {
                    Text(terminal.process.axodDescription)
                        .font(.body.weight(.medium))
                    Text("Work session \(terminal.runtime.target.sessionId.uuidString.lowercased()) · pane \(terminal.runtime.target.paneId.uuidString.lowercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Runtime \(terminal.runtime.runtimeGeneration.uuidString.lowercased()) · backlog \(terminal.backlogBytes) bytes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            if coordinator.nextRuntimeID != nil {
                Button("Load more runtimes") { coordinator.loadMoreRuntimes() }
                    .buttonStyle(.plain)
            }
        }
        .overlay {
            if coordinator.connectionState == .connected && coordinator.runtimes.isEmpty {
                ContentUnavailableView(
                    "No daemon runtimes",
                    systemImage: "server.rack",
                    description: Text("This view exposes metadata only. Terminal attachment and Pi chat admission are not available in this build.")
                )
            }
        }
        .tabItem { Label("Runtimes", systemImage: "server.rack") }
    }

    private var statusColor: Color {
        switch coordinator.connectionState {
        case .starting: .orange
        case .connected: .green
        case .disconnected: .secondary
        case .failed: .red
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
