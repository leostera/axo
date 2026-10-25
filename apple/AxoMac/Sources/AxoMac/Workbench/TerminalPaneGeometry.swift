import AxoProtocol
import CoreGraphics

/// Where panes land inside the terminal area. `TerminalSplitView` lays panes out with this, and
/// offscreen surfaces are sized with it, so a hidden pane already has the size it will be shown at.
enum TerminalPaneGeometry {
  static let dividerThickness: CGFloat = 1

  /// The lengths of a split's two panes along its axis.
  static func splitLengths(axisLength: CGFloat, ratio: Double) -> (first: CGFloat, second: CGFloat) {
    let available = max(0, axisLength - dividerThickness)
    let first = available * CGFloat(min(max(ratio, 0.01), 0.99))
    return (first, available - first)
  }

  /// Every pane's size when `layout` fills `size`.
  static func paneSizes(for layout: TerminalLayout, in size: CGSize) -> [ShellID: CGSize] {
    var sizes: [ShellID: CGSize] = [:]
    collect(layout, in: size, into: &sizes)
    return sizes
  }

  private static func collect(_ layout: TerminalLayout, in size: CGSize, into sizes: inout [ShellID: CGSize]) {
    switch layout {
    case .pane(let shellID):
      sizes[shellID] = size
    case .split(_, let direction, let ratio, let first, let second):
      switch direction {
      case .right:
        let lengths = splitLengths(axisLength: size.width, ratio: ratio)
        collect(first, in: CGSize(width: lengths.first, height: size.height), into: &sizes)
        collect(second, in: CGSize(width: lengths.second, height: size.height), into: &sizes)
      case .down:
        let lengths = splitLengths(axisLength: size.height, ratio: ratio)
        collect(first, in: CGSize(width: size.width, height: lengths.first), into: &sizes)
        collect(second, in: CGSize(width: size.width, height: lengths.second), into: &sizes)
      }
    }
  }
}
