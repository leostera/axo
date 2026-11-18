import AxoMobileModel
import SwiftUI

/// Available on every layer, not just in the requesting Session.
struct RequestsBell: View {
  var phone: PhoneWorkbench
  var open: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let count = phone.questions.filter { Double($0.elicitation.expiresAt) > context.date.timeIntervalSince1970 * 1_000 }.count
      Button(action: open) {
        Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
          .frame(width: 44, height: 44)
          .foregroundStyle(count > 0 ? Color.orange : .primary)
          .overlay(alignment: .topTrailing) {
            if count > 0 { Text("\(count)").font(.caption2.bold()).padding(4).background(.red, in: Capsule()).foregroundStyle(.white) }
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Requests, \(count) pending")
      .accessibilityIdentifier("elicitation-bell")
    }
  }
}

struct RequestsInbox: View {
  var phone: PhoneWorkbench
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let pending = phone.questions.filter { Double($0.elicitation.expiresAt) > context.date.timeIntervalSince1970 * 1_000 }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            if pending.isEmpty { Text("You’re all caught up.").foregroundStyle(.secondary) }
            ForEach(pending) { question in
              let host = phone.hosts.hosts.first { $0.hostId == question.hostID }
              let session = host.flatMap { phone.sessions(of: $0).first { $0.sessionId == question.elicitation.sessionId } }
              VStack(alignment: .leading, spacing: 6) {
                Text("\(host?.label ?? "Mac") · \(session?.displayName ?? "Session")")
                  .font(.caption).foregroundStyle(.secondary)
                ElicitationCards(phone: phone, questions: [question],
                  canAnswer: phone.link == .connected && host?.status == .online)
              }
            }
          }
          .padding(16)
        }
      }
      .navigationTitle("Requests")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
