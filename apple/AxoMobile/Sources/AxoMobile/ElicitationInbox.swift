import AxoMobileModel
import AxoProtocol
import SwiftUI

struct RequestsBell: View {
  var phone: PhoneWorkbench
  var open: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let count = phone.questions.filter { Double($0.elicitation.expiresAt) > context.date.timeIntervalSince1970 * 1_000 }.count
      Button(action: open) {
        Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
          .frame(width: 44, height: 44)
          .foregroundStyle(.primary)
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

/// A compact conversation switcher for outstanding requests, not a second notification feed.
/// Reviewing and answering belong in the conversation that supplies the context.
struct RequestsInbox: View {
  var phone: PhoneWorkbench
  var openConversation: (UUID, SessionID) -> Void
  @State private var showingSettings = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let pending = phone.questions.filter { Double($0.elicitation.expiresAt) > context.date.timeIntervalSince1970 * 1_000 }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if pending.isEmpty { Text("You’re all caught up.").foregroundStyle(.secondary) }
            ForEach(pending) { question in
              let host = phone.hosts.hosts.first { $0.hostId == question.hostID }
              let session = host.flatMap { phone.sessions(of: $0).first { $0.sessionId == question.elicitation.sessionId } }
              Button { openConversation(question.hostID, question.elicitation.sessionId) } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(question.elicitation.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                  HStack {
                    Text("\(session?.displayName ?? "Conversation") · \(host?.label ?? "Mac")")
                    Spacer()
                    Image(systemName: "chevron.right")
                  }.font(.caption).foregroundStyle(.secondary)
                }.askedCard()
              }.buttonStyle(.plain)
                .accessibilityIdentifier("request-conversation")
            }
          }.padding(12)
        }
      }
      .navigationTitle("Requests")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Settings", systemImage: "gearshape") { showingSettings = true }
            .accessibilityIdentifier("notification-settings")
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
      .sheet(isPresented: $showingSettings) {
        NavigationStack {
          NotificationPreferencesView()
            .toolbar { ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showingSettings = false }.accessibilityIdentifier("notification-settings-done")
            } }
        }
      }
    }
  }
}
