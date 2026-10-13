import AppKit
import AxoCore
import AxoProtocol
import Foundation
import SwiftUI

/// Actual production coordinator against an explicitly owned local fixture.
/// This is catalog/transport acceptance, not foreground, selection or IME proof.
@main struct CentralWorkbenchCatalogChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Owned fixture and helper required") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        checkPasteOriginRouting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axo-native-central-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]); process.arguments = [root.path]
        var environment = ProcessInfo.processInfo.environment; environment["HOME"] = root.path; environment["ZDOTDIR"] = root.path
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let directory = try AxodStateDirectory.openExisting(root: root)
        var endpoint: LocalDaemonEndpoint?
        try await wait {
            endpoint = try directory.readEndpoint()
            return endpoint != nil
        }
        let discovered = endpoint!
        let suite = "Axo.CentralWorkbenchCheck.\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let retired = "Axo.axod.selection.sessionID", opaque = Data([0x91, 0, 0xff, 0x23])
        preferences.set(opaque, forKey: retired)
        let coordinator = AxodWorkbenchCoordinator(preferences: preferences)
        try await coordinator.connectOwnedFixture(root: root, helper: URL(fileURLWithPath: CommandLine.arguments[2]))
        precondition(coordinator.connectionState == .connected && coordinator.catalog != nil)
        precondition(coordinator.sessions.isEmpty && coordinator.workspaces.isEmpty && coordinator.runtimes.isEmpty, "Connection does not create or start work")
        let peer = try AxoJSONRPCClient().openLocalWebSocket(endpoint: discovered)
        _ = try AxoProtocolResultValidator.localNegotiation(await peer.request(method: AxoProtocol.Method.negotiate, parameters: NegotiationParameters()))
        let bootstrap = try await call(CentralRequest.bootstrap(machine: .init(machineId: discovered.machineId, hostGeneration: discovered.hostGeneration)), peer)
        coordinator.createWorkspace(name: "Owned workspace", directoryPath: root.path)
        let workspaceTicket = coordinator.creations.pendingTicket!
        do { try await wait { coordinator.sessions.count == 1 && coordinator.workspaces.count == 1 && !coordinator.creations.hasPending } }
        catch {
            fputs("Workspace creation fixture state: message=\(coordinator.message) pending=\(coordinator.creations.hasPending) workspaces=\(coordinator.workspaces.count) sessions=\(coordinator.sessions.count) connection=\(coordinator.connectionState)\n", stderr)
            let request = try CentralRequest.operation(source: bootstrap.source, commandId: workspaceTicket.commandId)
            fputs("Workspace original observation: \(try await call(request, peer).payload)\n", stderr)
            throw error
        }
        guard case .operation(.createWorkspace(let original)?, _) = try await call(CentralRequest.operation(source: bootstrap.source, commandId: workspaceTicket.commandId), peer).payload else { fatalError("Original one-operation workspace graph") }
        precondition(original.graph.initialSession.panes.count == 2)
        coordinator.selectWorkspace(original.graph.workspace.workspaceId)
        coordinator.createSession()
        let sessionTicket = coordinator.creations.pendingTicket!
        try await wait { coordinator.sessions.count == 2 && !coordinator.creations.hasPending }
        guard case .operation(.createSession(let sessionOriginal)?, _) = try await call(CentralRequest.operation(source: bootstrap.source, commandId: sessionTicket.commandId), peer).payload else { fatalError("Original ⌘T complete session graph") }
        precondition(sessionOriginal.graph.panes.count == 2 && sessionOriginal.graph.session.workspaceId == original.graph.workspace.workspaceId)
        do { try await wait { coordinator.runtimes.count == 2 } }
        catch { fputs("Runtime fixture state: runtimes=\(coordinator.runtimes.count) message=\(coordinator.message)\n", stderr); throw error }
        precondition(coordinator.catalog?.source == bootstrap.source)
        precondition(coordinator.catalog?.sessions.allSatisfy { $0.readiness != .ready } == true, "No Pi policy cannot fabricate readiness")
        coordinator.selectSession(sessionOriginal.graph.session.sessionId)
        precondition(coordinator.selectedWorkspaceID == original.graph.workspace.workspaceId && coordinator.selectedSessionID == sessionOriginal.graph.session.sessionId)
        try await refreshUntilNotAdmitted(coordinator)
        precondition(coordinator.selectedPiObservation == .notAdmitted && coordinator.selectedPiHistory == nil &&
                     coordinator.selectedPiResponse?.payload == .piObservation(.notAdmitted) && !coordinator.selectedPiReadUnavailable,
            "A desired Pi pane without a committed admission is reported as not admitted, never as a fresh or empty conversation")
        guard let conversation = coordinator.piConversationPresentation(for: sessionOriginal.graph.session.sessionId, source: bootstrap.source) else {
            fatalError("Selected conversation captures its central source")
        }
        precondition((try? coordinator.piInputPresentation(matching: conversation)) == nil,
            "Input editing is unavailable until Axod publishes an admitted binding")
        coordinator.selectWorkspace(original.graph.workspace.workspaceId)
        precondition(coordinator.selectedSession?.workspaceId == original.graph.workspace.workspaceId,
            "Selecting a workspace retains a session within that workspace, independent of page ordering")
        try await checkNativeOutline(coordinator, source: bootstrap.source)
        let sessionRename = try coordinator.prepareSessionRename(sessionOriginal.graph.session.sessionId)
        coordinator.finishRename(sessionRename, name: "Manually renamed session")
        let sessionRenameTicket = coordinator.renames.pendingTicket!
        try await wait {
            coordinator.sessionView(sessionOriginal.graph.session.sessionId)?.session.name == "Manually renamed session" &&
            coordinator.sessionView(sessionOriginal.graph.session.sessionId)?.session.manualName == true && !coordinator.renames.hasPending
        }
        guard case .operation(.renameSession(let acceptedSession)?, _) = try await call(
            CentralRequest.operation(source: bootstrap.source, commandId: sessionRenameTicket.commandId), peer).payload
        else { fatalError("Manual Rename immutable original") }
        precondition(acceptedSession.graph.manualName && acceptedSession.graph.name == "Manually renamed session")
        let workspaceRename = try coordinator.prepareWorkspaceRename(original.graph.workspace.workspaceId)
        coordinator.finishRename(workspaceRename, name: "Manually renamed workspace")
        let workspaceRenameTicket = coordinator.renames.pendingTicket!
        try await wait {
            coordinator.workspaces.first(where: { $0.workspaceId == original.graph.workspace.workspaceId })?.name == "Manually renamed workspace" &&
            !coordinator.renames.hasPending
        }
        guard case .operation(.renameWorkspace(let acceptedWorkspace)?, _) = try await call(
            CentralRequest.operation(source: bootstrap.source, commandId: workspaceRenameTicket.commandId), peer).payload
        else { fatalError("Workspace Rename immutable original") }
        precondition(acceptedWorkspace.graph.name == "Manually renamed workspace")
        precondition(preferences.data(forKey: retired) == opaque, "Retired selection preference bytes are neither imported nor changed")
        let captured = coordinator.runtimes.map(\.runtime)
        coordinator.disconnect()
        precondition(coordinator.selectedPiObservation == nil && coordinator.selectedPiResponse == nil && coordinator.selectedPiHistory == nil,
            "Disconnect fences central Pi presentation state")
        precondition(process.isRunning, "Client disconnect is not lifecycle intent")
        let catalog = try await CentralCatalogLoader.load(source: bootstrap.source) { request in try await call(request, peer) }
        precondition(catalog.terminals.count == captured.count && catalog.terminals.allSatisfy { captured.contains($0.runtime) })
        precondition(catalog.terminals.allSatisfy { if case .running = $0.process { return true }; return false })
        try await coordinator.connectOwnedFixture(root: root, helper: URL(fileURLWithPath: CommandLine.arguments[2]))
        let retainedGeometry = coordinator.paneLayouts.trees.count
        let endpointFile = root.appendingPathComponent("local-endpoint.json")
        let withheldEndpoint = root.appendingPathComponent("withheld-endpoint.json")
        try FileManager.default.moveItem(at: endpointFile, to: withheldEndpoint)
        coordinator.refresh()
        try await wait { if case .failed = coordinator.connectionState { return true }; return false }
        precondition(coordinator.catalog == nil && process.isRunning, "Endpoint loss fences presentation, not daemon lifecycle")
        precondition(coordinator.paneLayouts.trees.count == retainedGeometry, "Endpoint absence cannot prove leaf completion")
        try FileManager.default.moveItem(at: withheldEndpoint, to: endpointFile)
        precondition(coordinator.catalog == nil, "Restored discovery does not automatically restore authority")
        await peer.close()
        print("PASS: central Mac coordinator, native sidebar, session-bound conversation window, not-admitted fence, endpoint loss and disconnect independence")
    }
    private static func checkPasteOriginRouting() {
        precondition(AxodPiEditOrigin.resolve(isPasting: false, capture: nil) == .direct,
            "Ordinary typing uses the live synchronous edit path")
        precondition(AxodPiEditOrigin.resolve(isPasting: true, capture: nil) == .rejectedPaste,
            "A paste without an exact capture is rejected instead of falling back to a retargetable edit")
    }
    @MainActor private static func checkNativeOutline(_ coordinator: AxodWorkbenchCoordinator, source: CentralSource) async throws {
        let controller = AxodNativeWorkbenchSplitView.SidebarController(workbench: coordinator, sidebarCollapsed: .constant(false))
        let root = controller.makeView(detail: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -1800, y: -1200, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        controller.update(workbench: coordinator, workspaces: coordinator.workspaces, sessions: coordinator.sessions,
            sessionDisplayNames: coordinator.sidebarSessionNames,
            selectedWorkspaceID: coordinator.selectedWorkspaceID, selectedSessionID: coordinator.selectedSessionID,
            sidebarCollapsed: .constant(false), detail: AnyView(EmptyView()))
        window.contentView?.layoutSubtreeIfNeeded()
        guard let workspace = coordinator.selectedWorkspaceID, let item = controller.fixtureWorkspaceItem(workspace) else { fatalError("Native workspace row") }
        controller.fixtureOutline.expandItem(item)
        let rows = controller.fixtureSessionRows()
        precondition(rows.count == 2 && rows[0].id != rows[1].id, "Both central sessions have native outline rows")
        let selected = Set(rows.map(\.id))
        controller.fixtureOutline.selectRowIndexes(IndexSet(rows.map(\.row)), byExtendingSelection: false)
        controller.fixtureSelectionDidChange()
        precondition(controller.fixtureSelectedSessionIDs() == selected, "Native outline multi-selection remains identity-based")
        let order = rows.map(\.id)
        let request = try CentralRequest.workspaces(source: source)
        let extraId = UUID()
        let extraRaw = try json(["hostGeneration": source.machine.hostGeneration.uuidString,
            "storeGeneration": source.storeGeneration.uuidString, "revision": coordinator.catalog!.revision.rawValue,
            "value": ["records": [["workspaceId": extraId.uuidString, "name": "Fixture addition", "directory": "/fixture/addition", "lifecycle": "open", "configRevision": coordinator.catalog!.revision.rawValue]], "cursor": NSNull()]])
        guard case .workspaces(let additions, _) = try request.parseResult(extraRaw).payload, let added = additions.first else { fatalError("Parsed fixture metadata") }
        controller.update(workbench: coordinator, workspaces: coordinator.workspaces + [added], sessions: coordinator.sessions.reversed(),
            sessionDisplayNames: coordinator.sidebarSessionNames,
            selectedWorkspaceID: coordinator.selectedWorkspaceID, selectedSessionID: coordinator.selectedSessionID,
            sidebarCollapsed: .constant(false), detail: AnyView(EmptyView()))
        precondition(controller.fixtureSessionRows().map(\.id) == order, "Catalog reordering and appended workspace do not reorder existing outline rows")
        precondition(controller.fixtureSelectedSessionIDs() == selected, "Metadata refresh preserves discontiguous session selection")
        precondition(controller.fixtureExpanded(workspace), "Metadata refresh preserves workspace expansion")
        let titleNames = coordinator.sidebarSessionNames.merging([order[0]: "Observed Pi title"]) { _, proposed in proposed }
        controller.update(workbench: coordinator, workspaces: coordinator.workspaces + [added], sessions: coordinator.sessions.reversed(),
            sessionDisplayNames: titleNames,
            selectedWorkspaceID: coordinator.selectedWorkspaceID, selectedSessionID: coordinator.selectedSessionID,
            sidebarCollapsed: .constant(false), detail: AnyView(EmptyView()))
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(controller.fixtureSessionNames()[order[0]] == "Observed Pi title",
            "A scoped title publication refreshes its row without rebuilding the native outline")
        precondition(controller.fixtureSessionRows().map(\.id) == order && controller.fixtureSelectedSessionIDs() == selected &&
                     controller.fixtureExpanded(workspace),
            "Title publication preserves native row order, selection and workspace expansion")
        guard let menu = controller.fixtureSessionMenu(order[0]),
              let conversationItem = menu.items.first(where: { $0.title == "Open Conversation" }),
              conversationItem.representedObject as? UUID == order[0],
              let action = conversationItem.action, let target = conversationItem.target else {
            fatalError("Session context menu routes to its exact central conversation")
        }
        precondition(NSApp.sendAction(action, to: target, from: conversationItem), "Session menu opens its bound conversation")
        precondition(coordinator.selectedSessionID == order[0])
        guard let captured = coordinator.piConversationPresentation(for: order[0], source: source) else {
            fatalError("Opened conversation captures its exact source and session")
        }
        coordinator.selectSession(order[1])
        precondition(coordinator.piConversationPresentation(for: order[0], source: source) == nil,
            "A previously opened conversation presentation cannot retarget after selection changes")
        precondition(coordinator.piConversationPresentation(for: order[1], source: source)?.id != captured.id,
            "A new session presentation receives a new edit fence")
        try await refreshUntilNotAdmitted(coordinator)
        precondition(coordinator.selectedPiObservation == .notAdmitted && coordinator.selectedPiHistory == nil,
            "Opening a session without an admitted Pi shows no fabricated empty or replacement conversation")
        guard let conversationWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "Axo.PiConversationWindow" }),
              conversationWindow.isVisible else { fatalError("Native conversation window is visible") }
        conversationWindow.close()
        precondition(!conversationWindow.isVisible, "Closing the conversation window releases its volatile editor presentation")
        window.close()
    }
    @MainActor private static func refreshUntilNotAdmitted(_ coordinator: AxodWorkbenchCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while coordinator.selectedPiObservation != .notAdmitted {
            await coordinator.refreshSelectedPi()
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            if coordinator.selectedPiObservation != .notAdmitted { try await Task.sleep(for: .milliseconds(100)) }
        }
    }
    private static func json(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @MainActor private static func wait(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func call(_ request: CentralRequest, _ peer: AxoJSONRPCWebSocketConnection) async throws -> CentralResponse {
        try request.parseResult(await peer.request(method: request.method, parameters: request.parameters))
    }
    private enum Failure: Error { case deadline }
}
