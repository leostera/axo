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
          if session.hasAgent != false {
            RestartPi(workbench: workbench, session: session)
              .padding(.top, 20)
          }
          if let state = session.workspaceState {
            WorkspaceFacts(state: state, host: workbench.hostLabel)
              .padding(.top, 20)
          }
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
      // The latest finished message (or its creation): `updatedAt` only says when the listing was sent.
      let active = ChatMenu.activity(session)
      if active != .distantPast {
        Fact(label: "Last active", value: active.formatted(.relative(presentation: .named)))
      }
      Fact(label: "Chat", value: session.sessionId.rawValue, monospaced: true)
    }
    .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private var status: String {
    if workbench.chat(session.sessionId).restart != nil { return "Restarting…" }
    return switch session.status {
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

/// Restarts the chat's Pi on its conversation, after asking: a reply it is writing stops
/// (RFD0033). Says "Restarting…" until Pi is ready again.
private struct RestartPi: View {
  let workbench: HostWorkbenchModel
  let session: RemoteSession
  @State private var confirming = false

  var body: some View {
    let restarting = workbench.chat(session.sessionId).restart != nil
    Button { confirming = true } label: {
      HStack(spacing: 10) {
        if restarting { ProgressView() } else { Image(systemName: "arrow.clockwise") }
        Text(restarting ? "Restarting…" : "Restart Pi")
        Spacer(minLength: 0)
      }
      .font(.body)
      .padding(.horizontal, 16).padding(.vertical, 13)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(restarting ? Color.secondary : Color.primary)
    .disabled(restarting || workbench.status != .online)
    .accessibilityIdentifier("restart-pi")
    .confirmationDialog("Restart Pi?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Restart Pi", role: .destructive) {
        Task { await workbench.restartPi(in: session.sessionId) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("A reply it is writing stops. The conversation is kept.")
    }
  }
}

/// The chat's folder and its repository, as its Mac last read them when the agent settled
/// (RFD0022): what continuing it somewhere else would need.
private struct WorkspaceFacts: View {
  let state: WorkspaceState
  let host: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("On \(host)")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        Fact(label: "Folder", value: Self.short(state.path), monospaced: true)
        if state.isRepository {
          Fact(label: "Branch", value: branch)
          if let head = state.head { Fact(label: "Commit", value: String(head.prefix(8)), monospaced: true) }
          Fact(label: "Changes", value: changes)
          if state.differsFromUpstream { Fact(label: "Upstream", value: "Not in step with the remote") }
        } else {
          Fact(label: "Repository", value: "None")
        }
        Fact(
          label: "Read",
          value: Date(timeIntervalSince1970: TimeInterval(state.at)).formatted(.relative(presentation: .named)))
      }
      .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .accessibilityIdentifier("workspace-state")
  }

  private var branch: String {
    if let branch = state.branch { return branch }
    return state.head.map { "Detached at \($0.prefix(8))" } ?? "Detached"
  }

  private var changes: String {
    switch state.changedCount {
    case 0: "None"
    case 1: "1 file"
    case let count: "\(count) files"
    }
  }

  /// A home folder path as people write it: `~/axo` rather than `/Users/leo/axo`.
  static func short(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" else { return path }
    let rest = parts.dropFirst(3).joined(separator: "/")
    return rest.isEmpty ? "~" : "~/" + rest
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
