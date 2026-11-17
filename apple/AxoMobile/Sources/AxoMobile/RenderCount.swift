import SwiftUI

/// How many times each view's `body` ran, for finding work the screen does that it need not
/// (`AXO_PHONE_PREVIEW_RENDERS=1`, simulator debug builds only). A UI test reads the counts from
/// a tiny label in the corner and checks, for example, that dragging the menu does not redraw
/// the conversation. Counting is not observed state: noting a render never causes another.
@MainActor
enum RenderCount {
  #if DEBUG && targetEnvironment(simulator)
    static let enabled = ProcessInfo.processInfo.environment["AXO_PHONE_PREVIEW_RENDERS"] == "1"
    private static var counts: [String: Int] = [:]

    static func note(_ view: String) {
      if enabled { counts[view, default: 0] += 1 }
    }

    /// `name=count` pairs, sorted by name.
    static var summary: String {
      counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
  #else
    static let enabled = false
    @inline(__always) static func note(_ view: String) {}
    static var summary: String { "" }
  #endif
}

/// The counts, refreshed a few times a second on their own, so showing them redraws nothing else.
struct RenderCountLabel: View {
  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { _ in
      Text(RenderCount.summary)
        .font(.system(size: 2))
        .opacity(0.02)
        .accessibilityIdentifier("render-counts")
    }
    .allowsHitTesting(false)
  }
}
