import AxoProtocol
import Foundation

@main struct PanePresentationChecks {
    @MainActor static func main() throws {
        let machine = UUID(), session = UUID(), pi = UUID(), shell = UUID()
        let identity = AxodPaneLayouts.Session(machineID: machine, sessionID: session)
        func record(shells: [UUID]) throws -> WorkSessionRecord {
            let panes = try shells.map { id -> ShellPaneRecord in
                let data = try JSONSerialization.data(withJSONObject: [
                    "paneId": id.uuidString, "kind": "shell", "state": "open",
                    "profileId": NSNull(), "runtime": NSNull(), "terminal": NSNull()
                ])
                return try JSONDecoder().decode(ShellPaneRecord.self, from: data)
            }
            return WorkSessionRecord(sessionId: session, workspaceId: nil, name: "Presentation fixture",
                nameSource: .manual, pi: .init(paneId: pi, chatId: nil, admission: .notAdmitted),
                runtime: nil, shellPanes: panes)
        }

        let layouts = AxodPaneLayouts()
        layouts.observe(try record(shells: [shell]), machineID: machine)
        let original = layouts.trees[identity]!
        let generation = layouts.generations[identity]!
        precondition(Set(original.root!.leaves().map(\.id)) == Set([pi, shell]))
        layouts.focus(pi, in: identity)
        let move = layouts.captureFocus(from: pi, direction: .right, in: identity)!
        precondition(layouts.isCurrent(move))

        // Unsupported input and stale callbacks leave the whole presentation unchanged.
        for ratio in [Double.nan, .infinity, 0.09, 0.91] {
            layouts.resize(original.root!, ratio: ratio, in: identity, generation: generation)
        }
        precondition(layouts.generations[identity] == generation && layouts.isCurrent(move))
        layouts.resize(original.root!, ratio: 0.65, in: identity, generation: generation)
        precondition(!layouts.isCurrent(move))
        let resizedGeneration = layouts.generations[identity]!
        layouts.resize(original.root!, ratio: 0.4, in: identity, generation: generation)
        precondition(layouts.generations[identity] == resizedGeneration)
        layouts.equalize(identity, generation: resizedGeneration)
        precondition(layouts.trees[identity]!.root == original.root)
        precondition(layouts.generations[identity] != generation && !layouts.isCurrent(move))

        // Focus ABA and metadata-only refresh cannot revive an old captured action.
        let newMove = layouts.captureFocus(from: pi, direction: .right, in: identity)!
        layouts.focus(shell, in: identity)
        layouts.focus(pi, in: identity)
        precondition(!layouts.isCurrent(newMove))
        let currentMove = layouts.captureFocus(from: pi, direction: .right, in: identity)!
        layouts.focus(UUID(), in: identity)
        layouts.observe(try record(shells: []), machineID: machine)
        precondition(layouts.isCurrent(currentMove) && layouts.trees[identity]!.count == 2)

        let otherMachine = UUID()
        layouts.observe(try record(shells: [shell]), machineID: otherMachine)
        precondition(layouts.trees[.init(machineID: otherMachine, sessionID: session)]?.count == 2)
        precondition(layouts.isCurrent(currentMove))

        // Reject duplicate and over-capacity observations before any partial insertion.
        let beforeRejected = layouts.generations[identity]
        layouts.observe(try record(shells: [shell, shell]), machineID: machine)
        layouts.observe(try record(shells: (0..<32).map { _ in UUID() }), machineID: machine)
        layouts.observe(try record(shells: (0..<31).map { _ in UUID() }), machineID: machine)
        precondition(layouts.generations[identity] == beforeRejected && layouts.trees[identity]!.count == 2)

        let fresh = AxodPaneLayouts()
        precondition(fresh.trees.isEmpty && fresh.focusedPanes.isEmpty)
        fresh.observe(try record(shells: (0..<31).map { _ in UUID() }), machineID: machine)
        precondition(fresh.trees[identity]?.count == AxodPaneLayouts.maximumPanes)
        precondition(layouts.isCurrent(currentMove))
        print("PASS volatile pane presentation: fresh instances, exact scopes, focus/layout ABA, stale/invalid callbacks and atomic capacity rejection")
    }
}
