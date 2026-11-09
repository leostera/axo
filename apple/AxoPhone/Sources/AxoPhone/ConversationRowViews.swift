import AxoPhoneModel
import AxoProtocol
import SwiftUI

// The pieces of the conversation's list. Each reads what it shows itself, so a change redraws
// that piece and not the list: the list reads only its rows, which change when one is added.

/// One row of the conversation. It reads its own row, so it redraws when its row changes and when
/// nothing else does; its inputs are references, so the list redrawing (a row added) leaves it be.
struct ConversationItemView: View {
  let item: ConversationFeed.Item
  let feed: ConversationFeed
  let actions: ConversationRowActions

  var body: some View {
    switch item.row {
    case .message(let shown):
      ChatMessageView(
        message: shown.message,
        // Only a tool's row asks whether Pi is working, so only tools redraw when it starts or stops.
        piIsWorking: shown.isLive || (shown.message.role == .tool && feed.working),
        isLive: shown.isLive, entrance: entrance(of: shown))
    case .pending(let prompt):
      PendingPromptView(
        prompt: prompt, editAgain: { actions.editAgain(prompt) }, dismiss: { actions.dismiss(prompt) })
    case .queued(let prompt):
      QueuedPromptView(prompt: prompt)
    }
  }

  private func entrance(of shown: ConversationReveal.Shown) -> ChatMessageView.Entrance? {
    guard shown.presentation != .plain else { return nil }
    let feed = feed
    return ChatMessageView.Entrance(reveal: feed.reveal, presentation: shown.presentation) {
      feed.finished(shown.message.key)
    }
  }
}

/// What a pending message's buttons do, for the chat on screen. A reference the rows share, so a
/// row compares equal to itself however often the list redraws.
@MainActor
final class ConversationRowActions {
  private var session: SessionID?
  private weak var workbench: HostWorkbenchModel?
  private weak var phone: PhoneWorkbench?

  func chat(_ session: SessionID?, workbench: HostWorkbenchModel?, phone: PhoneWorkbench) {
    self.session = session
    self.workbench = workbench
    self.phone = phone
  }

  /// Puts its words back in the box, and takes it away.
  func editAgain(_ prompt: HostWorkbenchModel.PendingPrompt) {
    if let phone, let selection = phone.selection { phone.setDraft(prompt.text, for: selection) }
    dismiss(prompt)
  }

  func dismiss(_ prompt: HostWorkbenchModel.PendingPrompt) {
    if let session { workbench?.dismissPending(prompt.id, in: session) }
  }
}

/// At the top of the conversation: older messages are read as this scrolls into view.
struct OlderHistoryRow: View {
  let chat: Chat?
  let load: () -> Void

  var body: some View {
    switch chat?.history {
    case .loaded(_, true):
      Button("Load earlier messages", action: load)
        .font(.caption).frame(maxWidth: .infinity)
        .onAppear(perform: load)
    case .loadingOlder:
      LoadingMascotView(label: "Loading earlier messages").frame(height: 44).frame(maxWidth: .infinity)
    default:
      EmptyView()
    }
  }
}

/// A conversation with no rows: loading, failed, or with nothing in it yet.
struct ConversationEmptyState: View {
  let chat: Chat?
  /// A chat that does not exist yet.
  let isNew: Bool
  let canSend: Bool
  let pull: ConversationPull

  var body: some View {
    switch chat?.history {
    case nil, .loading:
      if isNew {
        ChatEmptyState(message: canSend ? "Send a message to start a chat." : "Your Mac is offline.", pull: pull)
      } else {
        LoadingMascotView(label: "Loading the conversation")
          .frame(height: 120).frame(maxWidth: .infinity).padding(.vertical, 70)
      }
    case .failed(let message):
      ChatEmptyState(message: message, pull: pull)
    case .loaded(let events, _), .loadingOlder(let events):
      ChatEmptyState(
        message: events == 0 ? "Nothing here yet." : "\(events) stored events, none of them messages yet.",
        pull: pull)
    }
  }
}

/// What the chat's extensions ask, answered here.
struct ElicitationCards: View {
  let phone: PhoneWorkbench
  let session: SessionID
  let canAnswer: Bool

  var body: some View {
    ForEach(phone.questions(in: session)) { question in
      if question.elicitation.input != nil {
        InputCard(question: question, canAnswer: canAnswer, failure: phone.answerFailure) { action, values in
          Task { await phone.answer(question.id, action, values: values) }
        }
      } else {
        ElicitationCard(question: question, canAnswer: canAnswer, failure: phone.answerFailure) { action in
          Task { await phone.answer(question.id, action) }
        }
      }
    }
  }
}

/// Below the rows: what Pi asks, and what it is doing while it works.
struct ConversationFooter: View {
  let feed: ConversationFeed
  let chat: Chat?
  let workbench: HostWorkbenchModel?
  let session: SessionID
  let canSend: Bool

  var body: some View {
    if let question = feed.question {
      QuestionCard(question: question, canAnswer: canSend) { answer in
        Task { await workbench?.answer(answer, in: session) }
      }
    }
    if feed.working {
      AgentActivityView(
        callingTools: feed.callingTools,
        waiting: feed.question != nil,
        stopping: chat?.isStopping == true,
        canStop: workbench?.status == .online,
        stop: { Task { await workbench?.stopReply(in: session) } })
    }
  }
}

/// Watches the end of the conversation for the screen to follow, drawing nothing: what it reads
/// changes as a reply grows, and redraws only this.
struct EndWatcher: View {
  let feed: ConversationFeed
  let chat: Chat?
  /// Something new at the end: a row added, the last one grown, Pi starting, stopping or asking.
  let changed: () -> Void
  /// The person sent a message.
  let sent: () -> Void

  private struct End: Equatable {
    var rows: ConversationFeed.End
    var working: Bool
    var asking: Bool
  }

  var body: some View {
    Color.clear
      .onChange(of: End(rows: feed.end, working: feed.working, asking: feed.question != nil)) { changed() }
      .onChange(of: chat?.pending.count ?? 0) { previous, count in
        if count > previous { sent() }
      }
  }
}
