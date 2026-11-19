import SwiftUI

struct WatchVoiceGlass: ViewModifier {
  func body(content: Content) -> some View {
    if #available(watchOS 26, *) {
      content.glassEffect(.clear, in: Capsule())
    } else {
      content.background(.ultraThinMaterial, in: Capsule())
    }
  }
}

struct WatchVoiceCircle: View {
  let symbol: String
  let label: String
  var prominent = false
  var compact = false
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: symbol == "arrow.up" ? 17 : 18, weight: prominent ? .semibold : .regular))
        .foregroundStyle(prominent ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
        .frame(width: compact ? 28 : 44, height: compact ? 28 : 44)
        .background(prominent ? Color.primary : Color.secondary.opacity(0.15), in: Circle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }
}
