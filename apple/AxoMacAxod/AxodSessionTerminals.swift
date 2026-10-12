import AxoProtocol
import SwiftUI

struct AxodSessionTerminals: View {
    let session: WorkSessionRecord
    let coordinator: AxodWorkbenchCoordinator
    @State private var initialFraction: CGFloat = 0.5
    // One viewport owner per scene/session presentation, not per split branch.
    @State private var viewportID = UUID()

    private var shellPlaceholder: String {
        switch coordinator.shellStartupState(for: session.sessionId) {
        case .starting?: "Starting…"
        case .unresolved?: "Start unconfirmed"
        case .ready?: "Connecting…"
        case .unavailable?, .rejected?, nil: "Shell unavailable"
        }
    }

    private var identity: AxodPaneLayouts.Session? {
        coordinator.machineID.map { .init(machineID: $0, sessionID: session.sessionId) }
    }
    var body: some View {
        VStack(spacing: 0) {
            AxodShellSplitNotice(sessionID: session.sessionId, identity: identity, coordinator: coordinator)
            if !session.shellPanes.isEmpty, let identity, let root = coordinator.paneLayouts.trees[identity]?.root,
               let generation = coordinator.paneLayouts.generations[identity] {
                AxodPaneSubtree(node: root, session: session, identity: identity, generation: generation, viewportID: viewportID, coordinator: coordinator)
                    .id(root.structuralIdentity)
            } else {
                // The initial shell has no committed identity yet. Geometry is
                // only a placeholder here, never a fabricated PTY or add intent.
                SplitView(.horizontal, $initialFraction, dividerColor: Color(nsColor: .separatorColor), left: {
                    AxodRuntimeTerminalPane(sessionID: session.sessionId,
                        snapshot: coordinator.presentationSnapshot(for: session), viewportID: viewportID, coordinator: coordinator)
                }, right: {
                    AxodTerminalInlineState(title: "Shell", message: shellPlaceholder,
                        details: coordinator.shellStartupState(for: session.sessionId)?.message)
                }, onEqualize: { initialFraction = 0.5 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.shellPanes.map(\.paneId)) { coordinator.preparePaneLayout(session) }
    }
}

private struct AxodShellSplitNotice: View {
    let sessionID: UUID
    let identity: AxodPaneLayouts.Session?
    let coordinator: AxodWorkbenchCoordinator
    var body: some View {
        let state = coordinator.shellStartupState(for: sessionID)
        let notice = identity.flatMap { coordinator.paneLayouts.notices[$0] }
        let placement = identity.flatMap { coordinator.paneLayouts.pendingCommand($0) }
        let canCheckPlacement = placement.map { state != .starting($0) } ?? false
        let title: String? = switch state {
        case .starting?: "Starting shell…"
        case .unresolved?: "Shell start unconfirmed"
        case .unavailable?, .rejected?: "Shell unavailable"
        case .ready?, nil: canCheckPlacement ? "Split unconfirmed" : (notice == nil ? nil : "Layout needs attention")
        }
        if let title {
            AxodStatusNotice(title, details: [state?.message, notice].compactMap { $0 }.joined(separator: "\n")) {
                if case .unresolved? = state {
                    Button("Check Status") { coordinator.reconcileSelectedShell() }
                } else if canCheckPlacement {
                    Button("Check Status") { coordinator.reconcileSelectedShell() }
                }
            }
        }
    }
}

/// Adapted from the pinned upstream TerminalSplitTreeView. Geometry mutations
/// use SplitTree's immutable operations and reject stale captured nodes.
/// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT; see Ghostty/LICENSE.txt.
private struct AxodPaneSubtree: View {
    let node: AxodPaneLayouts.Tree.Node
    let session: WorkSessionRecord
    let identity: AxodPaneLayouts.Session
    let generation: UUID
    let viewportID: UUID
    let coordinator: AxodWorkbenchCoordinator
    var body: some View {
        switch node {
        case .leaf(let leaf):
            let isPi = leaf.id == session.pi.paneId
            AxodRuntimeTerminalPane(sessionID: session.sessionId,
                snapshot: isPi ? coordinator.presentationSnapshot(for: session) : session.shellPanes.first(where: { $0.paneId == leaf.id })?.terminal,
                viewportID: viewportID, coordinator: coordinator)
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
    let viewportID: UUID
    let coordinator: AxodWorkbenchCoordinator
    @State private var launch: TerminalLaunch?
    @State private var failure: String?

    private struct Refresh: Equatable {
        let runtime: TerminalRuntime?
        let connection: AxodWorkbenchCoordinator.ConnectionState
    }
    var body: some View {
        VStack(spacing: 0) {
            if let launch = currentLaunch {
                if let notice = coordinator.terminalSurfaces.notices[launch.key] {
                    AxodStatusNotice("Terminal needs attention", details: notice) { EmptyView() }
                }
                AxodTerminalHost(launch: launch, surfaces: coordinator.terminalSurfaces, inputEnabled: isRunning,
                    viewportID: viewportID, onFocus: { [weak coordinator] in coordinator?.focusTerminal(launch.key) },
                    onAvailable: { [weak coordinator] window in coordinator?.terminalBecameAvailable(launch.key, in: window) })
                    .id(launch.key)
            } else {
                AxodTerminalInlineState(title: nil, message: failure == nil ? pendingMessage : "Terminal unavailable",
                    details: failure ?? snapshot?.process.axodDescription)
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
        snapshot?.process.axodStatusTitle ?? "Starting…"
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
    let details: String?

    init(title: String?, message: String, details: String? = nil) {
        self.title = title
        self.message = message
        self.details = details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.system(size: 11, weight: .medium)) }
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            if let details {
                DisclosureGroup("Details") { Text(details).textSelection(.enabled) }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
