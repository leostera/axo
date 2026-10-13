import AxoProtocol
import SwiftUI

struct AxodSessionTerminals: View {
    let session: CentralSession
    let coordinator: AxodWorkbenchCoordinator
    // One viewport owner per scene/session presentation, not per split branch.
    @State private var viewportID = UUID()

    private var desiredPaneIDs: [UUID] {
        coordinator.sessionView(session.sessionId)?.panes.filter { $0.desired.present }.map { $0.desired.paneId } ?? []
    }
    private var identity: AxodPaneLayouts.Session? {
        coordinator.catalog.map { .init(source: $0.source, sessionID: session.sessionId) }
    }
    var body: some View {
        VStack(spacing: 0) {
            if let identity, let layout = coordinator.paneLayouts.trees[identity]?.root,
               let root = AxodLivePaneTree.presenting(layout, paneIDs: desiredPaneIDs),
               let generation = coordinator.paneLayouts.generations[identity] {
                AxodPaneSubtree(node: root, session: session, identity: identity, generation: generation, viewportID: viewportID, coordinator: coordinator)
                    .id(root.structuralIdentity)
            } else {
                ProgressView("Opening session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: desiredPaneIDs) { coordinator.preparePaneLayout(session) }
    }
}

/// Adapted from the pinned upstream TerminalSplitTreeView. Geometry mutations
/// use SplitTree's immutable operations and reject stale captured nodes.
/// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT; see Ghostty/LICENSE.txt.
private struct AxodPaneSubtree: View {
    let node: AxodPaneLayouts.Tree.Node
    let session: CentralSession
    let identity: AxodPaneLayouts.Session
    let generation: UUID
    let viewportID: UUID
    let coordinator: AxodWorkbenchCoordinator
    var body: some View {
        switch node {
        case .leaf(let leaf):
            let pane = coordinator.sessionView(session.sessionId)?.panes.first { $0.desired.paneId == leaf.id }
            let isPi = pane?.desired.role == .pi
            AxodRuntimeTerminalPane(sessionID: session.sessionId, snapshot: pane?.terminal,
                availability: pane?.availability, viewportID: viewportID, coordinator: coordinator)
                .id(leaf.id)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isPi ? "Pi terminal pane" : "Shell terminal pane")
        case .split(let split):
            SplitView(split.direction == .horizontal ? .horizontal : .vertical,
                Binding(get: { CGFloat(split.ratio) }, set: { coordinator.paneLayouts.resize(node, ratio: Double($0), in: identity, generation: generation) }),
                dividerColor: Color(nsColor: .separatorColor),
                left: { AxodPaneSubtree(node: split.left, session: session, identity: identity, generation: generation, viewportID: viewportID, coordinator: coordinator) },
                right: { AxodPaneSubtree(node: split.right, session: session, identity: identity, generation: generation, viewportID: viewportID, coordinator: coordinator) },
                onEqualize: { coordinator.paneLayouts.equalize(identity, generation: generation) })
        }
    }
}

private struct AxodRuntimeTerminalPane: View {
    let sessionID: UUID
    let snapshot: TerminalSnapshot?
    let availability: CentralAvailability?
    let viewportID: UUID
    let coordinator: AxodWorkbenchCoordinator
    @State private var launch: TerminalLaunch?
    @State private var failure: String?

    private struct Refresh: Equatable {
        let runtime: TerminalRuntime?
        let source: CentralSource?
        let connection: AxodWorkbenchCoordinator.ConnectionState
    }
    var body: some View {
        VStack(spacing: 0) {
            if let launch = currentLaunch {
                if coordinator.terminalSurfaces.notices[launch.key] != nil {
                    AxodStatusNotice("Terminal needs attention") { EmptyView() }
                }
                AxodTerminalHost(launch: launch, surfaces: coordinator.terminalSurfaces, inputEnabled: isRunning,
                    viewportID: viewportID, onFocus: { [weak coordinator] in coordinator?.focusTerminal(launch.key) },
                    onAvailable: { _ in })
                    .id(launch.key)
            } else {
                AxodTerminalInlineState(title: nil, message: failure == nil ? pendingMessage : "Terminal unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Refresh(runtime: snapshot?.runtime, source: coordinator.catalog?.source, connection: coordinator.connectionState)) { prepareAttachment() }
    }

    private var isRunning: Bool {
        if let snapshot, case .running = snapshot.process { return true }
        return false
    }
    private var currentLaunch: TerminalLaunch? {
        guard coordinator.connectionState == .connected, isRunning, let launch, let runtime = snapshot?.runtime,
              let source = coordinator.catalog?.source, launch.key.namespace == .centralStore(source.storeGeneration),
              launch.key.machineID == coordinator.machineID,
              launch.key.sessionID == sessionID,
              launch.key.hostGeneration == runtime.hostGeneration,
              launch.key.paneID == runtime.target.paneId,
              launch.key.runtimeGeneration == runtime.runtimeGeneration else { return nil }
        return launch
    }
    private var pendingMessage: String {
        switch availability {
        case .live: return snapshot?.process.axodStatusTitle ?? "Terminal unavailable"
        case .materializing, .restarting: return "Opening session…"
        case .stopping: return "Stopping…"
        case .stopped: return "Session ended"
        case .blocked, nil: return "Session unavailable"
        }
    }
    private func prepareAttachment() {
        guard !Task.isCancelled else { return }
        guard let snapshot, case .running = snapshot.process else { failure = nil; return }
        do {
            let captured = try coordinator.terminalLaunch(for: snapshot, sessionID: sessionID)
            guard !Task.isCancelled else { return }
            launch = captured
            failure = nil
        } catch { failure = error.localizedDescription }
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
