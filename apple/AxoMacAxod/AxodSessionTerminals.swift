import AxoProtocol
import SwiftUI

struct AxodSessionTerminals: View {
    let session: WorkSessionRecord
    let coordinator: AxodWorkbenchCoordinator
    @State private var fraction: CGFloat = 0.5

    var body: some View {
        // Use the pinned upstream primitive, not a second split geometry engine.
        SplitView(.horizontal, $fraction, dividerColor: Color(nsColor: .separatorColor), left: {
            AxodRuntimeTerminalPane(title: "Pi", sessionID: session.sessionId,
                                    snapshot: session.runtime, coordinator: coordinator)
        }, right: {
            if session.shellPanes.isEmpty {
                AxodTerminalInlineState(title: "Shell", message: "An independent regular shell has not been created for this session.")
                    .frame(minWidth: 240)
            } else {
                VStack(spacing: 1) {
                    ForEach(session.shellPanes) { pane in
                        AxodRuntimeTerminalPane(title: "Shell", sessionID: session.sessionId,
                                                snapshot: pane.terminal, coordinator: coordinator)
                            .id(pane.paneId)
                    }
                }
                .frame(minWidth: 240)
            }
        }, onEqualize: { fraction = 0.5 })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AxodRuntimeTerminalPane: View {
    let title: String
    let sessionID: UUID
    let snapshot: TerminalSnapshot?
    let coordinator: AxodWorkbenchCoordinator
    @State private var launch: TerminalLaunch?
    @State private var failure: String?

    private struct Refresh: Equatable {
        let runtime: TerminalRuntime?
        let connection: AxodWorkbenchCoordinator.ConnectionState
    }
    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 5)
            if let launch = currentLaunch {
                if let notice = coordinator.terminalSurfaces.notices[launch.key] {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                AxodTerminalHost(launch: launch, surfaces: coordinator.terminalSurfaces, inputEnabled: isRunning)
                    .id(launch.key)
            } else {
                AxodTerminalInlineState(title: nil, message: failure ?? pendingMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Refresh(runtime: snapshot?.runtime, connection: coordinator.connectionState)) { prepareAttachment() }
    }

    private var isRunning: Bool {
        if let snapshot, case .running = snapshot.process { return true }
        return false
    }

    private var currentLaunch: TerminalLaunch? {
        guard let launch, let runtime = snapshot?.runtime,
              launch.key.machineID == coordinator.machineID,
              launch.key.sessionID == sessionID,
              launch.key.hostGeneration == runtime.hostGeneration,
              launch.key.paneID == runtime.target.paneId,
              launch.key.runtimeGeneration == runtime.runtimeGeneration else { return nil }
        return launch
    }

    private var pendingMessage: String {
        if let snapshot { return "Runtime \(snapshot.process.axodDescription); no process was started by this viewport." }
        return "Waiting for the daemon-owned PTY. Startup and uncertainty remain inline."
    }
    private func prepareAttachment() {
        guard !Task.isCancelled else { return }
        guard let snapshot, case .running = snapshot.process else { failure = nil; return }
        do {
            let captured = try coordinator.terminalLaunch(for: snapshot, sessionID: sessionID)
            guard !Task.isCancelled else { return }
            launch = captured
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct AxodTerminalInlineState: View {
    let title: String?
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .medium)) }
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
