import AppKit
import SwiftUI
import AxoCore

/// Stable NSView leaf for Ghostty's generic tree. Decoding creates an empty host,
/// never a terminal/process; WorkspaceController alone owns explicit launches.
final class PaneHostView: NSView, Codable, Identifiable {
    let id: UUID
    init(id: PaneID) { self.id = id.rawValue; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Programmatic view only") }
    required init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(UUID.self)
        super.init(frame: .zero)
    }
    func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(id) }
    func show(_ view: NSView) {
        if subviews.count == 1, subviews.first === view { return }
        subviews.forEach { $0.removeFromSuperview() }
        view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
    }
}

/// Adapted from Ghostty's TerminalSplitTreeView: same structural identity and
/// immutable resize operations, with Axo leaves instead of Ghostty app globals.
/// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT; see Ghostty/LICENSE.txt.
struct PaneSplitTreeView: View {
    typealias Tree = SplitTree<PaneHostView>
    let tree: Tree
    let focusedPane: PaneID?
    let resize: (Tree.Node, Double) -> Void
    let equalize: () -> Void

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            Subtree(node: node, focusedPane: focusedPane, resize: resize, equalize: equalize)
                .id(node.structuralIdentity)
        }
    }
    private struct Subtree: View {
        let node: Tree.Node
        let focusedPane: PaneID?
        let resize: (Tree.Node, Double) -> Void
        let equalize: () -> Void
        var body: some View {
            switch node {
            case .leaf(let view):
                Leaf(view: view)
                    .overlay {
                        if let focusedPane, focusedPane.rawValue != view.id {
                            Color.black.opacity(0.055)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .animation(.easeInOut(duration: 0.12), value: focusedPane)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Terminal pane")
            case .split(let split):
                SplitView(split.direction == .horizontal ? .horizontal : .vertical,
                          Binding(get: { CGFloat(split.ratio) }, set: { resize(node, Double($0)) }),
                          dividerColor: Color(nsColor: .separatorColor),
                          left: { Subtree(node: split.left, focusedPane: focusedPane, resize: resize, equalize: equalize) },
                          right: { Subtree(node: split.right, focusedPane: focusedPane, resize: resize, equalize: equalize) },
                          onEqualize: equalize)
            }
        }
    }
    private struct Leaf: NSViewRepresentable {
        let view: PaneHostView
        func makeNSView(context: Context) -> PaneHostView { view }
        func updateNSView(_ view: PaneHostView, context: Context) {}
    }
}

extension SplitTree where ViewType == PaneHostView {
    func savedLayout() -> PaneLayout? { root.map(Self.savedNode) }
    private static func savedNode(_ node: Node) -> PaneLayout {
        switch node {
        case .leaf(let view): return .pane(PaneID(view.id))
        case .split(let split):
            return .split(axis: split.direction == .horizontal ? .horizontal : .vertical,
                          fraction: split.ratio, first: savedNode(split.left), second: savedNode(split.right))
        }
    }
}
