import AxoProtocol
import Foundation

/// Parsed central metadata drives volatile geometry; no writer/runtime is faked.
@main struct CentralPanePresentationChecks {
    @MainActor static func main() throws {
        let source = try CentralSource(machine: .init(machineId: UUID(), hostGeneration: UUID()), storeGeneration: UUID())
        let session = UUID(), pi = UUID(), shell = UUID()
        func view(_ shells: [UUID]) throws -> CentralSessionView {
            let panes = ([pi] + shells).enumerated().map { ordinal, id -> [String: Any] in
                ["desired": ["paneId": id.uuidString, "sessionId": session.uuidString, "role": ["kind": ordinal == 0 ? "pi" : "accountShell"], "present": true, "ordinal": ordinal, "configRevision": 1], "availability": "blocked", "lastRuntime": NSNull(), "terminal": NSNull()]
            }
            let body: [String: Any] = ["session": ["sessionId": session.uuidString, "workspaceId": NSNull(), "name": "Central session", "manualName": false, "lifecycle": "open", "configRevision": 1], "panes": panes, "readiness": "blocked"]
            let raw = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: ["hostGeneration": source.machine.hostGeneration.uuidString, "storeGeneration": source.storeGeneration.uuidString, "revision": 1, "value": body]))
            let response = try CentralRequest.session(source: source, workspaceId: nil, sessionId: session).parseResult(raw)
            guard case .session(let view) = response.payload else { fatalError("Central view") }
            return view
        }
        let layouts = AxodPaneLayouts(), key = AxodPaneLayouts.Session(source: source, sessionID: session)
        layouts.observe(try view([shell]), source: source)
        precondition(layouts.trees[key]?.count == 2)
        layouts.focus(pi, in: key)
        let move = layouts.captureFocus(from: pi, direction: .right, in: key)!
        precondition(move.destination == shell && layouts.isCurrent(move))
        layouts.focus(shell, in: key); layouts.focus(pi, in: key)
        precondition(!layouts.isCurrent(move), "Equal-looking focus ABA is not the original responder")
        let node = layouts.trees[key]!.root!, generation = layouts.generations[key]!
        layouts.resize(node, ratio: 0.7, in: key, generation: generation)
        precondition(layouts.generations[key] != generation)
        let resized = layouts.trees[key]!.root
        layouts.resize(node, ratio: 0.5, in: key, generation: generation)
        precondition(layouts.trees[key]?.root == resized, "Stale divider callbacks do not mutate geometry")
        layouts.observe(try view([UUID()]), source: source)
        precondition(layouts.trees[key]?.count == 3, "New desired metadata cannot prune an older retained leaf without completion")
        let otherStore = try CentralSource(machine: source.machine, storeGeneration: UUID())
        layouts.observe(try view([shell]), source: otherStore)
        let other = AxodPaneLayouts.Session(source: otherStore, sessionID: session)
        precondition(other != key && layouts.trees[other]?.count == 2)
        precondition(layouts.focusedPanes[other] == nil, "A different store cannot inherit focus")
        let full = AxodPaneLayouts()
        full.observe(try view((0..<31).map { _ in UUID() }), source: source)
        precondition(full.trees[key]?.count == 32)
        let before = full.trees[key]?.root
        full.observe(try view([UUID()]), source: source)
        precondition(full.trees[key]?.root == before, "Capacity never evicts retained geometry")
        print("PASS: central desired-pane geometry, store/focus/divider fences and bounded retention")
    }
}
