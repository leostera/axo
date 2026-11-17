import SwiftUI

/// Reposition the same editor and controls instead of swapping view trees during focus changes.
struct ComposerIslandLayout: Layout {
  let expanded: Bool
  private let gap: CGFloat = 8
  private let rowGap: CGFloat = 4

  private func measurements(width: CGFloat, subviews: Subviews) -> (add: CGSize, editor: CGSize, actions: CGSize) {
    let add = subviews[0].sizeThatFits(.unspecified)
    let actions = subviews[2].sizeThatFits(
      ProposedViewSize(width: expanded ? max(1, width - add.width - gap) : nil, height: nil))
    let editorWidth = expanded ? width : max(1, width - add.width - actions.width - gap * 2)
    let editor = subviews[1].sizeThatFits(ProposedViewSize(width: editorWidth, height: nil))
    return (add, editor, actions)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 320
    let sizes = measurements(width: width, subviews: subviews)
    let controls = max(sizes.add.height, sizes.actions.height)
    return CGSize(width: width, height: expanded
      ? sizes.editor.height + rowGap + controls
      : max(sizes.editor.height, controls))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let sizes = measurements(width: bounds.width, subviews: subviews)
    let editorWidth = expanded ? bounds.width : max(1, bounds.width - sizes.add.width - sizes.actions.width - gap * 2)
    let controlsY = expanded ? bounds.minY + sizes.editor.height + rowGap
      : bounds.midY - max(sizes.add.height, sizes.actions.height) / 2
    subviews[0].place(at: CGPoint(x: bounds.minX, y: controlsY), anchor: .topLeading,
      proposal: ProposedViewSize(sizes.add))
    subviews[1].place(
      at: CGPoint(x: expanded ? bounds.minX : bounds.minX + sizes.add.width + gap,
        y: expanded ? bounds.minY : bounds.midY - sizes.editor.height / 2),
      anchor: .topLeading, proposal: ProposedViewSize(width: editorWidth, height: sizes.editor.height))
    subviews[2].place(at: CGPoint(x: bounds.maxX - sizes.actions.width, y: controlsY), anchor: .topLeading,
      proposal: ProposedViewSize(sizes.actions))
  }
}
