/// Presentation-only navigation. These directions never create or remove a pane.
enum AxodPaneFocusDirection: CaseIterable {
    case left, right, up, down, previous, next
    var treeDirection: SplitTree<AxodPaneLayoutLeaf>.FocusDirection {
        switch self {
        case .left: return .spatial(.left)
        case .right: return .spatial(.right)
        case .up: return .spatial(.up)
        case .down: return .spatial(.down)
        case .previous: return .previous
        case .next: return .next
        }
    }
}
