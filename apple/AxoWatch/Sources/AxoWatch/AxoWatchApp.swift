import SwiftUI
import WatchKit

@main
struct AxoWatchApp: App {
  var body: some Scene {
    WindowGroup {
      WatchPlayground()
    }
  }
}

private struct WatchPlayground: View {
  @State private var taps = 0

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 12) {
          Image(systemName: "sparkles")
            .font(.largeTitle)
            .foregroundStyle(.mint)
            .accessibilityHidden(true)

          Text("Axo on your wrist")
            .font(.headline)
            .multilineTextAlignment(.center)

          Text("A little playground.")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            taps += 1
            WKInterfaceDevice.current().play(.click)
          } label: {
            Label("Tap me", systemImage: "hand.tap")
          }
          .tint(.mint)

          Text(taps == 1 ? "1 tap" : "\(taps) taps")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("tapCount")
        }
        .padding(.horizontal)
      }
      .navigationTitle("Axo")
    }
  }
}

#Preview {
  WatchPlayground()
}
