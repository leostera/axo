import AppKit
import AxoProtocol
import Foundation
import Observation

/// Volatile native geometry and focus. No desired intent, command hints or persistence.
@MainActor @Observable
final class AxodPaneLayouts {
    typealias Tree = SplitTree<AxodPaneLayoutLeaf>
    struct Session: Hashable {
        let machineID: UUID
        let sessionID: UUID
    }
    struct FocusMove {
        let session: Session
        let source: UUID
        let destination: UUID
        let layoutGeneration: UUID
        let focusGeneration: UUID
    }

    static let maximumPanes = 32
    private var focusGenerations: [Session: UUID] = [:]
    private(set) var trees: [Session: Tree] = [:]
    private(set) var generations: [Session: UUID] = [:]
    private(set) var focusedPanes: [Session: UUID] = [:]

    func observe(_ record: WorkSessionRecord, machineID: UUID) {
        let paneIDs = [record.pi.paneId] + record.shellPanes.map(\.paneId)
        guard paneIDs.count <= Self.maximumPanes, Set(paneIDs).count == paneIDs.count else { return }
        let session = Session(machineID: machineID, sessionID: record.sessionId)
        var tree = trees[session] ?? Tree(view: AxodPaneLayoutLeaf(id: record.pi.paneId))
        let missing = record.shellPanes.filter { tree.find(id: $0.paneId) == nil }
        // An older observation cannot remove retained leaves. Refuse a whole
        // over-capacity update instead of publishing a partially inserted set.
        guard tree.count + missing.count <= Self.maximumPanes,
              case .leaf(let anchor)? = tree.find(id: record.pi.paneId) else { return }
        for pane in missing {
            guard let next = try? tree.inserting(view: AxodPaneLayoutLeaf(id: pane.paneId), at: anchor, direction: .right) else { return }
            tree = next
        }
        replaceTree(tree, in: session)
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

    func resize(_ node: Tree.Node, ratio: Double, in session: Session, generation: UUID) {
        guard generations[session] == generation, ratio.isFinite, (0.1...0.9).contains(ratio),
              let tree = trees[session], tree.contains(node), case .split = node,
              let next = try? tree.replacing(node: node, with: node.resizing(to: ratio)) else { return }
        replaceTree(next, in: session)
    }

    func equalize(_ session: Session, generation: UUID) {
        guard generations[session] == generation, let tree = trees[session] else { return }
        replaceTree(tree.equalized(), in: session)
    }

    private func replaceTree(_ tree: Tree, in session: Session) {
        guard trees[session]?.root != tree.root else { return }
        // Layout and focus generations fence callbacks even after equal-looking ABA.
        trees[session] = tree
        generations[session] = UUID()
    }
}
