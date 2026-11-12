import SwiftUI
import WatchKit

/// Frames of the same Rive Face artboard used by iPhone. No animation runtime on the Watch.
struct WatchMascot: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var happy = false

  var body: some View {
    Image(happy ? "AxoHappy" : "AxoFace")
      .resizable().renderingMode(.original).scaledToFit()
      .scaleEffect(happy && !reduceMotion ? 1.08 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: happy)
      .contentShape(Rectangle())
      .onTapGesture { happy = true; WKInterfaceDevice.current().play(.click) }
      .task(id: happy) {
        guard happy else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        happy = false
      }
      .accessibilityLabel("Axo mascot")
      .accessibilityAddTraits(.isButton)
  }
}

struct WatchBrandHeader: View {
  var body: some View {
    VStack(spacing: 0) {
      WatchMascot().frame(width: 96, height: 55)
      Text("axo").font(.custom("Fredoka-Bold", size: 32, relativeTo: .largeTitle))
    }
    .padding(.vertical, 6)
  }
}
