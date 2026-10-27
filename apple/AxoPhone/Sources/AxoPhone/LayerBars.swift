import SwiftUI

extension View {
  /// Buttons pinned to the top or bottom of a layer, floating over its scrolling content with no
  /// band of background behind them, as the conversation's title and message box float. On iOS 26
  /// the system bar reserves the space and fades the content under it (see `softLayerEdges`).
  @ViewBuilder
  func layerBar<Bar: View>(edge: VerticalEdge, @ViewBuilder _ bar: () -> Bar) -> some View {
    if #available(iOS 26, *) {
      safeAreaBar(edge: edge, spacing: 0, content: bar)
    } else {
      safeAreaInset(edge: edge, spacing: 0, content: bar)
    }
  }

  /// Content scrolling under a `layerBar` fades out instead of ending at a line.
  @ViewBuilder
  func softLayerEdges() -> some View {
    if #available(iOS 26, *) {
      scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      self
    }
  }

  /// A round control floating over content: a blurred disc with a hairline edge, like the
  /// conversation's menu button.
  func floatingCircle(diameter: CGFloat = 44) -> some View {
    frame(width: diameter, height: diameter)
      .background(.ultraThinMaterial, in: Circle())
      .overlay { Circle().stroke(ChatColors.border, lineWidth: 0.5) }
  }
}
