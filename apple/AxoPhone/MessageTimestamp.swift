import SwiftUI

/// Provider/Pi time, not the time an older history page happened to arrive.
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
            .accessibilityIdentifier("message-timestamp")
            .popover(isPresented: $showExactTime) {
                Text(exactTime).font(.callout).textSelection(.enabled).padding(20)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func relativeTime(at now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private var exactTime: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .long
        return formatter.string(from: date)
    }
}
