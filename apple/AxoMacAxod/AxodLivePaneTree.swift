import Foundation

/// A volatile rendering projection, never desired topology or runtime ownership.
@MainActor
enum AxodLivePaneTree {
    static func presenting(_ layout: AxodPaneLayouts.Tree.Node, paneIDs: [UUID]) -> AxodPaneLayouts.Tree.Node? {
        let live = Array(paneIDs.prefix(AxodPaneLayouts.maximumPanes))
        var root = keeping(layout, paneIDs: Set(live))
        for paneID in live where !(root?.leaves().contains { $0.id == paneID } ?? false) {
            let leaf = AxodPaneLayouts.Tree.Node.leaf(view: AxodPaneLayoutLeaf(id: paneID))
            if let existing = root { root = .split(.init(direction: .horizontal, ratio: 0.5, left: existing, right: leaf)) }
            else { root = leaf }
        }
        return root
    }

    static func keeping(_ node: AxodPaneLayouts.Tree.Node, paneIDs: Set<UUID>) -> AxodPaneLayouts.Tree.Node? {
        switch node {
        case .leaf(let leaf): return paneIDs.contains(leaf.id) ? node : nil
        case .split(let split):
            let left = keeping(split.left, paneIDs: paneIDs)
            let right = keeping(split.right, paneIDs: paneIDs)
            switch (left, right) {
            case (let left?, let right?):
                return .split(.init(direction: split.direction, ratio: split.ratio, left: left, right: right))
            case (let remaining?, nil), (nil, let remaining?): return remaining
            case (nil, nil): return nil
            }
        }
    }
}
