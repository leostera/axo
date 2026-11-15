import SwiftUI

/// Optional fixture observation of actual laid-out controls, not ideal sizes or pixels.
/// No geometry observers are installed in production, where the callback is nil.
enum SetupLayoutElement: Hashable {
  case back, primary, review, viewport, scrollHint, commandInstall
  case row(SetupItem)
}
typealias SetupLayoutObserver = @MainActor (SetupLayoutElement, CGRect?) -> Void

extension View {
  @MainActor
  @ViewBuilder
  func setupLayout(_ element: SetupLayoutElement, observer: SetupLayoutObserver?) -> some View {
    if let observer {
      onGeometryChange(for: CGRect.self) { $0.frame(in: .named("axo-setup-layout")) } action: {
        observer(element, $0)
      }
      .onDisappear { observer(element, nil) }
    } else {
      self
    }
  }
}
