import AppKit
import AxoProtocol
import Foundation
import Observation

/// Native-local geometry and focus, never process ownership or launch authority.
@MainActor @Observable
final class AxodPaneLayouts {
    typealias Tree = SplitTree<AxodPaneLayoutLeaf>
    struct Session: Hashable {
        let machineID: UUID
        let sessionID: UUID
    }
    struct Placement {
        let parameters: ShellPaneAddParameters
        let anchor: UUID
        let direction: AxodPaneSplitDirection
    }
    struct FocusMove {
        let session: Session
        let source: UUID
        let destination: UUID
        let layoutGeneration: UUID
        let focusGeneration: UUID
    }
    private var focusGenerations: [Session: UUID] = [:]
    static let maximumPanes = 32 // Same presentation capacity, including Pi.
    @ObservationIgnored private let preferences: UserDefaults
    private(set) var trees: [Session: Tree] = [:]
    private(set) var generations: [Session: UUID] = [:]
    private(set) var focusedPanes: [Session: UUID] = [:]
    private(set) var notices: [Session: String] = [:]
    private var unreadableLayouts: Set<Session> = []

    init(preferences: UserDefaults) { self.preferences = preferences }

    func observe(_ record: WorkSessionRecord, machineID: UUID) {
        let session = Session(machineID: machineID, sessionID: record.sessionId)
        if trees[session] == nil {
            if let saved = preferences.object(forKey: layoutKey(session)) {
                if let data = saved as? Data, let tree = AxodPaneLayoutPersistence.read(data, session: session),
                   tree.find(id: record.pi.paneId) != nil {
                    replaceTree(tree, in: session)
                } else {
                    unreadableLayouts.insert(session)
                    notices[session] = "The saved split layout could not be read. It was preserved; no work was started."
                }
            }
            if trees[session] == nil { replaceTree(Tree(view: AxodPaneLayoutLeaf(id: record.pi.paneId)), in: session) }
        }
        guard var tree = trees[session] else { return }
        // Absence from a potentially older catalog is not removal authority.
        // Keep missing leaves inert until an explicit removal receipt is adopted.
        for pane in record.shellPanes where tree.find(id: pane.paneId) == nil {
            guard tree.count < Self.maximumPanes,
                  case .leaf(let anchor)? = tree.find(id: record.pi.paneId),
                  let next = try? tree.inserting(view: AxodPaneLayoutLeaf(id: pane.paneId), at: anchor, direction: .right) else { continue }
            tree = next
        }
        replaceTree(tree, in: session)
        save(tree, session: session)
        if preferences.object(forKey: placementKey(session)) != nil && pendingPlacement(session) == nil {
            notices[session] = "The saved split intent could not be read. It was preserved; no second shell was sent."
        }
    }

    func pendingParameters(_ session: Session) -> ShellPaneAddParameters? { pendingPlacement(session)?.parameters }
    func pendingCommand(_ session: Session) -> UUID? { pendingParameters(session)?.commandId }

    func canSplit(_ session: Session) -> Bool {
        !unreadableLayouts.contains(session) && preferences.object(forKey: placementKey(session)) == nil &&
        (trees[session]?.count ?? Self.maximumPanes) < Self.maximumPanes
    }

    func focus(_ paneID: UUID, in session: Session) {
        guard trees[session]?.find(id: paneID) != nil, focusedPanes[session] != paneID else { return }
        focusedPanes[session] = paneID
        focusGenerations[session] = UUID()
    }

    func captureFocus(from paneID: UUID, direction: AxodPaneFocusDirection, in session: Session) -> FocusMove? {
        guard focusedPanes[session] == paneID, let focusGeneration = focusGenerations[session],
              let layoutGeneration = generations[session], let tree = trees[session], let node = tree.find(id: paneID),
              let destination = tree.focusTarget(for: direction.treeDirection, from: node), destination.id != paneID else { return nil }
        return FocusMove(session: session, source: paneID, destination: destination.id,
            layoutGeneration: layoutGeneration, focusGeneration: focusGeneration)
    }
    func isCurrent(_ move: FocusMove) -> Bool {
        generations[move.session] == move.layoutGeneration && focusGenerations[move.session] == move.focusGeneration &&
            focusedPanes[move.session] == move.source && trees[move.session]?.find(id: move.destination) != nil
    }

    /// Save the captured placement before the original explicit pane command.
    /// The companion shell hint owns reconciliation; neither hint permits replay.
    func capture(parameters: ShellPaneAddParameters, anchor: UUID, direction: AxodPaneSplitDirection) -> Placement? {
        let session = Session(machineID: parameters.target.machineId, sessionID: parameters.target.sessionId)
        guard canSplit(session), trees[session]?.find(id: anchor) != nil else { return nil }
        let placement = Placement(parameters: parameters, anchor: anchor, direction: direction)
        guard let data = AxodPaneLayoutPersistence.write(placement) else { return nil }
        preferences.set(data, forKey: placementKey(session))
        notices.removeValue(forKey: session)
        return placement
    }

    func commit(_ placement: Placement, paneID: UUID) {
        let session = Session(machineID: placement.parameters.target.machineId, sessionID: placement.parameters.target.sessionId)
        guard let saved = pendingPlacement(session), saved.parameters == placement.parameters,
              saved.anchor == placement.anchor, saved.direction == placement.direction,
              var tree = trees[session] else { return }
        // A catalog may have already presented the new committed leaf. Relocate
        // it using the original anchor, not current focus or selection.
        if let existing = tree.find(id: paneID) { tree = tree.removing(existing) }
        guard paneID != placement.anchor, case .leaf(let anchor)? = tree.find(id: placement.anchor),
              tree.count < Self.maximumPanes,
              let next = try? tree.inserting(view: AxodPaneLayoutLeaf(id: paneID), at: anchor,
                direction: placement.direction == .right ? .right : .down) else {
            notices[session] = "The shell was added, but its original split anchor is unavailable. No work was resent."
            finishKnownCommand(placement)
            return
        }
        replaceTree(next, in: session)
        save(next, session: session)
        finishKnownCommand(placement)
    }

    func adopt(_ receipt: ShellPaneReceipt, in session: Session) {
        guard let placement = pendingPlacement(session), receipt.commandId == placement.parameters.commandId,
              receipt.intent == .add(target: placement.parameters.target, profileId: placement.parameters.profileId) else { return }
        switch receipt.disposition {
        case .added: commit(placement, paneID: receipt.paneId)
        case .rejected: finishKnownCommand(placement)
        case .prepared, .removed: break
        }
    }

    func noDispatch(_ placement: Placement) {
        let session = Session(machineID: placement.parameters.target.machineId, sessionID: placement.parameters.target.sessionId)
        notices[session] = "The split could not reach the local daemon. No new shell command was sent."
        finishKnownCommand(placement)
    }

    func finishKnownCommand(_ placement: Placement) {
        let session = Session(machineID: placement.parameters.target.machineId, sessionID: placement.parameters.target.sessionId)
        guard let saved = pendingPlacement(session), saved.parameters == placement.parameters else { return }
        preferences.removeObject(forKey: placementKey(session))
    }

    func resize(_ node: Tree.Node, ratio: Double, in session: Session, generation: UUID) {
        guard !unreadableLayouts.contains(session), generations[session] == generation,
              ratio.isFinite, (0.1...0.9).contains(ratio),
              let tree = trees[session], tree.contains(node), case .split = node,
              let next = try? tree.replacing(node: node, with: node.resizing(to: ratio)) else { return }
        replaceTree(next, in: session)
        save(next, session: session)
    }

    func equalize(_ session: Session, generation: UUID) {
        guard !unreadableLayouts.contains(session), generations[session] == generation, let tree = trees[session] else { return }
        let next = tree.equalized()
        replaceTree(next, in: session)
        save(next, session: session)
    }

    private func replaceTree(_ tree: Tree, in session: Session) {
        guard trees[session]?.root != tree.root else { return }
        // One actor-owned mutation: generation also rejects equal-looking ABA
        // callbacks after a layout changed and subsequently returned to that shape.
        trees[session] = tree
        generations[session] = UUID()
    }

    private func save(_ tree: Tree, session: Session) {
        guard !unreadableLayouts.contains(session), let data = AxodPaneLayoutPersistence.write(tree, session: session),
              preferences.data(forKey: layoutKey(session)) != data else { return }
        preferences.set(data, forKey: layoutKey(session))
    }
    private func pendingPlacement(_ session: Session) -> Placement? {
        guard let data = preferences.data(forKey: placementKey(session)),
              let placement = AxodPaneLayoutPersistence.readPlacement(data, session: session) else { return nil }
        return placement
    }
    private func layoutKey(_ session: Session) -> String {
        "Axo.axod.paneLayout.\(session.machineID.uuidString).\(session.sessionID.uuidString)"
    }
    private func placementKey(_ session: Session) -> String {
        "Axo.axod.pendingPanePlacement.\(session.machineID.uuidString).\(session.sessionID.uuidString)"
    }
}
