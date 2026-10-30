import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// The layer over the conversation, pulled in from the right: what the phone knows about the
/// open chat. A first version, with what the listing and the transcript already carry.
struct SessionInfoPanel: View {
  let workbench: HostWorkbenchModel?
  let session: RemoteSession?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        OwnMascotView(loading: session?.status == .working)
          .frame(width: 132)
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
          .padding(.bottom, 8)
        Text(title)
          .font(.title3.weight(.semibold))
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("session-info-title")
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .multilineTextAlignment(.center)
          .padding(.top, 4)
          .padding(.bottom, 24)
        if let session, let workbench {
          SessionFacts(workbench: workbench, session: session)
        } else {
          Text("Nothing here yet. Send a message and this chat starts on your Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 24)
    }
    .scrollIndicators(.hidden)
    .background(ChatColors.background)
    .accessibilityIdentifier("session-info")
  }

  private var title: String {
    guard let session else { return "New chat" }
    return [session.emoji, session.displayName].compactMap { $0 }.joined(separator: " ")
  }

  private var subtitle: String {
    guard let workbench else { return "No Mac" }
    return [session?.workspaceName, workbench.hostLabel].compactMap { $0 }.joined(separator: " · ")
  }
}

/// The facts about one chat, as rows of a label and a value. Reads the chat's own transcript, so
/// a reply streaming in redraws this and nothing else.
private struct SessionFacts: View {
  let workbench: HostWorkbenchModel
  let session: RemoteSession

  var body: some View {
    let chat = workbench.chat(session.sessionId)
    VStack(spacing: 0) {
      Fact(label: "Status", value: status)
      Fact(label: "Mac", value: workbench.status == .online ? "\(workbench.hostLabel), online" : "\(workbench.hostLabel), offline")
      if let workspace = session.workspaceName { Fact(label: "Workspace", value: workspace) }
      Fact(label: "Messages", value: messages(chat))
      Fact(label: "Terminals", value: session.shells.count.formatted())
      if let updated = try? Date(session.updatedAt, strategy: .iso8601) {
        Fact(label: "Last active", value: updated.formatted(.relative(presentation: .named)))
      }
      Fact(label: "Chat", value: session.sessionId.rawValue, monospaced: true)
    }
    .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var status: String {
    switch session.status {
    case .starting: "Starting"
    case .ready: "Ready"
    case .working: "Working"
    case .needsAttention: "Needs you"
    case .unavailable: "Unavailable"
    case nil: "Unknown"
    }
  }

  private func messages(_ chat: Chat) -> String {
    guard let transcript = chat.transcript else { return "Not loaded" }
    let count = transcript.messages.count
    // Only the newest pages are loaded until the chat is scrolled back.
    switch chat.history {
    case .loaded(_, hasOlder: true), .loadingOlder: return "\(count)+"
    default: return count.formatted()
    }
  }
}

private struct Fact: View {
  let label: String
  let value: String
  var monospaced = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Text(value)
        .font(monospaced ? .footnote.monospaced() : .body)
        .multilineTextAlignment(.trailing)
        .lineLimit(monospaced ? 2 : 1)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .accessibilityElement(children: .combine)
  }
}
