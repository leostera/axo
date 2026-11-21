import SwiftUI

/// A native button owns activation, shortcuts and accessibility. The kit owns its ink and fill.
public struct AxoPrimaryButton: View {
  private let title: String
  private let action: () -> Void

  public init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  public var body: some View {
    Button(title, action: action).buttonStyle(PrimaryStyle())
  }
}

private struct PrimaryStyle: ButtonStyle {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    let dark = scheme == .dark
    let fill = enabled ? (dark ? 1.0 : 0.0) : (dark ? 0.75 : 0.35)
    return configuration.label
      .foregroundStyle(dark ? Color.black : Color.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(Capsule().fill(Color(.sRGB, white: fill, opacity: 1)))
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
  }
}
