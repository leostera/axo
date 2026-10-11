import AppKit
import AxoCore
import AxoProtocol
import Foundation

/// Deterministic local geometry/hint checks, not execution or native acceptance.
@main
struct PaneLayoutChecks {
    @MainActor static func main() async throws {
        let suite = "Axo.PaneLayoutCheck.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let machine = UUID(), host = UUID(), sessionID = UUID(), pi = UUID()
        let identity = AxodPaneLayouts.Session(machineID: machine, sessionID: sessionID)
        let session = WorkSessionRecord(sessionId: sessionID, workspaceId: nil, name: "Fixture", nameSource: .manual,
            pi: .init(paneId: pi, chatId: nil, admission: .notAdmitted), runtime: nil)
        func parameters() -> ShellPaneAddParameters {
            .init(target: .init(machineId: machine, hostGeneration: host, workspaceId: nil, sessionId: sessionID), commandId: UUID())
        }
        let layouts = AxodPaneLayouts(preferences: preferences)
        layouts.observe(session, machineID: machine)
        let first = parameters(), firstPane = UUID()
        let right = layouts.capture(parameters: first, anchor: pi, direction: .right)!
        precondition(layouts.pendingParameters(identity) == first)
        precondition(AxodEmptyStartupPolicy.hasPendingIntent(in: preferences, machineID: machine))
        precondition(layouts.capture(parameters: parameters(), anchor: pi, direction: .down) == nil)
        layouts.commit(right, paneID: firstPane)
        guard case .split(let root)? = layouts.trees[identity]?.root else { preconditionFailure() }
        precondition(root.direction == .horizontal && root.left.leaves().map(\.id) == [pi] && root.right.leaves().map(\.id) == [firstPane])
        precondition(!AxodEmptyStartupPolicy.hasPendingIntent(in: preferences, machineID: machine))
        let second = parameters(), secondPane = UUID()
        let down = layouts.capture(parameters: second, anchor: firstPane, direction: .down)!
        layouts.focus(pi, in: identity) // A later focus change cannot move captured placement.
        layouts.commit(down, paneID: secondPane)
        guard case .split(let divided)? = layouts.trees[identity]?.root,
              case .split(let shellSplit) = divided.right else { preconditionFailure() }
        precondition(shellSplit.direction == .vertical)
        precondition(shellSplit.left.leaves().map(\.id) == [firstPane] && shellSplit.right.leaves().map(\.id) == [secondPane])
        let oldRoot = layouts.trees[identity]!.root!, oldGeneration = layouts.generations[identity]!
        layouts.resize(oldRoot, ratio: 0.65, in: identity, generation: oldGeneration)
        layouts.resize(oldRoot, ratio: 0.2, in: identity, generation: oldGeneration) // stale node rejected
        guard case .split(let resized)? = layouts.trees[identity]?.root else { preconditionFailure() }
        precondition(resized.ratio == 0.65)
        layouts.resize(layouts.trees[identity]!.root!, ratio: 0.5, in: identity, generation: layouts.generations[identity]!)
        layouts.resize(oldRoot, ratio: 0.2, in: identity, generation: oldGeneration) // equal-looking ABA rejected
        guard case .split(let roundTrip)? = layouts.trees[identity]?.root else { preconditionFailure() }
        precondition(roundTrip.ratio == 0.5)
        layouts.resize(layouts.trees[identity]!.root!, ratio: 0.65, in: identity, generation: layouts.generations[identity]!)
        let restored = AxodPaneLayouts(preferences: preferences)
        restored.observe(session, machineID: machine)
        precondition(restored.trees[identity]?.count == 3)
        guard case .split(let restoredRoot)? = restored.trees[identity]?.root else { preconditionFailure() }
        precondition(restoredRoot.ratio == 0.65)
        // Restore preserved missing leaves as inert geometry, never launched work.
        let data = AxodPaneLayoutPersistence.write(restored.trees[identity]!, session: identity)!
        precondition(AxodPaneLayoutPersistence.read(data, session: .init(machineID: UUID(), sessionID: sessionID)) == nil)
        func saved(_ root: JSONValue) throws -> Data {
            try JSONEncoder().encode(JSONValue.object(["version": .number(1), "machineId": .string(machine.uuidString),
                "sessionId": .string(sessionID.uuidString), "root": root]))
        }
        let leaf: JSONValue = .object(["kind": .string("pane"), "paneId": .string(pi.uuidString)])
        let duplicate: JSONValue = .object(["kind": .string("split"), "axis": .string("horizontal"), "fraction": .number(0.5), "first": leaf, "second": leaf])
        let duplicateData = try saved(duplicate)
        precondition(AxodPaneLayoutPersistence.read(duplicateData, session: identity) == nil)
        let extra: JSONValue = .object(["kind": .string("pane"), "paneId": .string(pi.uuidString), "argv": .array([])])
        let extraData = try saved(extra)
        precondition(AxodPaneLayoutPersistence.read(extraData, session: identity) == nil)
        precondition(AxodPaneLayoutPersistence.read(Data(repeating: 0x20, count: 16385), session: identity) == nil)
        var deep = leaf
        for _ in 0..<33 {
            deep = .object(["kind": .string("split"), "axis": .string("vertical"), "fraction": .number(0.5),
                "first": deep, "second": .object(["kind": .string("pane"), "paneId": .string(UUID().uuidString)])])
        }
        let deepData = try saved(deep)
        precondition(AxodPaneLayoutPersistence.read(deepData, session: identity) == nil)
        let layoutKey = "Axo.axod.paneLayout.\(machine.uuidString).\(sessionID.uuidString)"
        preferences.set(Data([0xff]), forKey: layoutKey)
        let corrupt = AxodPaneLayouts(preferences: preferences)
        corrupt.observe(session, machineID: machine)
        precondition(!corrupt.canSplit(identity) && preferences.data(forKey: layoutKey) == Data([0xff]))
        preferences.set(data, forKey: layoutKey)
        let splitKey = "Axo.axod.pendingPanePlacement.\(machine.uuidString).\(sessionID.uuidString)"
        preferences.set("opaque", forKey: splitKey)
        let opaque = AxodPaneLayouts(preferences: preferences)
        opaque.observe(session, machineID: machine)
        precondition(!opaque.canSplit(identity) && opaque.notices[identity] != nil)
        precondition(preferences.string(forKey: splitKey) == "opaque")
        preferences.removeObject(forKey: splitKey)
        // Original command ID is shared by placement and shell hint. Null receipt
        // reconciliation cannot clear either hint or send another pane command.
        let uncertain = parameters()
        let pending = restored.capture(parameters: uncertain, anchor: firstPane, direction: .right)!
        let creation = AxodShellCreation(preferences: preferences)
        var sends = 0
        _ = await creation.start(session: session, source: .init(machineId: machine, hostGeneration: host), commandID: uncertain.commandId, send: { request in
            sends += 1
            precondition(request == pending.parameters && restored.pendingParameters(identity) == request)
            throw AxoJSONRPCClientError.outcomeUnknown(requestID: "fixture")
        }, validate: {})
        let reread = AxodPaneLayouts(preferences: preferences)
        reread.observe(session, machineID: machine)
        precondition(!reread.canSplit(identity) && reread.pendingParameters(identity) == uncertain)
        let receipt = await creation.reconcile(session: session, source: .init(machineId: machine, hostGeneration: host),
            parameters: reread.pendingParameters(identity), lookup: { lookup in
                precondition(lookup.commandId == uncertain.commandId)
                return .object(["hostGeneration": .string(host.uuidString), "receipt": .null])
            }, validate: {})
        precondition(receipt == nil && sends == 1 && reread.pendingParameters(identity) == uncertain)
        print("PASS: captured right/down geometry, stale resize refusal, bounded closed layout restoration, opaque hint preservation and original split command/no-replay (local state only)")
    }
}
