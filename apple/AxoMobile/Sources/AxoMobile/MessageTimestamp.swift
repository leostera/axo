import SwiftUI

/// Pi's time for a message, not the time an older page of history happened to arrive. Tap for the exact time.
struct MessageTimestamp: View {
  let milliseconds: Int64
  @State private var showExactTime = false

  private var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { timeline in
      Button { showExactTime = true } label: {
        Text(relativeTime(at: timeline.date)).font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Message timestamp")
      .accessibilityValue(relativeTime(at: timeline.date))
      .popover(isPresented: $showExactTime) {
        Text(exactTime).font(.callout).textSelection(.enabled).padding(20)
          .presentationCompactAdaptation(.popover)
      }
    }
  }

  // Made once: a formatter is costly to set up, and every message on screen has a timestamp.
  private static let relative: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()
  private static let exact: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .long
    return formatter
  }()

  private func relativeTime(at now: Date) -> String { Self.relative.localizedString(for: date, relativeTo: now) }

  private var exactTime: String { Self.exact.string(from: date) }
}
