import SwiftUI

/// Session-independent entry point; the native app currently observes this Mac's daemon.
struct RequestsButton: View {
  let model: ElicitationsModel
  var body: some View {
    let count = model.questions.count
    Button { QuestionsPanel.shared.show(model) } label: {
      HStack(spacing: 2) {
        Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
          .font(.system(size: 11, weight: .medium))
        Text(count > 0 ? "\(count)" : " ")
          .foregroundStyle(count > 0 ? Color.red : Color.secondary)
          .font(.system(size: 9, weight: .semibold).monospacedDigit())
          .frame(width: 12)
      }
      .foregroundStyle(count > 0 ? Color.orange : Color.secondary)
      .frame(width: 34, height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Requests on this Mac")
    .accessibilityLabel("Requests, \(count) pending")
    .accessibilityIdentifier("elicitation-bell")
  }
}
