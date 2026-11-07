import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Where a Session's records come from: the account's socket (RFD0018). The one chat on screen
/// is open, so its new records arrive as they are written; each batch is acknowledged once taken,
/// which lets the next one come.
public protocol ChatFeed: Sendable {
  func open(_ session: SessionID, on host: UUID, have: (epoch: Int64, cursor: Int64)?, window: Int) async throws -> ClientOpenResult
  func older(_ session: SessionID, before: Int64, limit: Int) async throws -> ClientOlderPage
  func acknowledge(_ session: SessionID, cursor: Int64) async
  func close(_ session: SessionID) async
}

extension AccountConnection: ChatFeed {}

/// One chat's state on the phone. Each chat is observed on its own: an event in one chat redraws
/// that chat, and not the one on screen.
@MainActor
@Observable
public final class Chat {
  /// What the agent has said, from stored history plus what has happened since; nil until
  /// anything is known.
  public fileprivate(set) var transcript: ChatTranscript?
  public fileprivate(set) var history: HostWorkbenchModel.HistoryState?
  /// Messages the phone sent that the agent has not recorded yet, oldest first.
  public fileprivate(set) var pending: [HostWorkbenchModel.PendingPrompt] = []
  /// The person asked to stop the reply, and Pi has not stopped yet.
  public fileprivate(set) var isStopping = false
  /// Where a restart of the chat's Pi asked for here is (RFD0033); nil when none is.
  public fileprivate(set) var restart: HostWorkbenchModel.Restart?
  /// The slash commands its Pi takes, as last read; nil until they are.
  public fileprivate(set) var commands: [PiCommand]?
  /// The models its Pi could switch to, as last read; nil until they are.
  public fileprivate(set) var models: [PiModel]?
  /// A model or thinking level picked here, shown until the chat's listing says what Pi runs.
  public fileprivate(set) var chosen: PiRuntime?
  /// The epoch the records held belong to.
  fileprivate var epoch: Int64?
  /// The `before` of the next older page; nil when the start is held.
  fileprivate var older: Int64?

  nonisolated init() {}
}

/// One host opened on the phone: its Sessions, whether it is online, and what the agent says in
/// each. Everything comes from the account's socket, which `PhoneWorkbench` follows and hands on;
/// nothing is stored here.
@MainActor
@Observable
public final class HostWorkbenchModel {
  /// The Mac's name, as the account lists it now (a person may rename it while it is open).
  public private(set) var hostLabel: String
  public let reference: RemoteHostRef
  public private(set) var status: RemoteHostStatus
  public private(set) var sessions: [RemoteSession]
  /// Each chat's state. Not observed as a whole: views observe the one `Chat` they show.
  @ObservationIgnored private var chatStore: [SessionID: Chat] = [:]

  /// The chat for `id`, made the first time it is asked for.
  public func chat(_ id: SessionID) -> Chat {
    if let chat = chatStore[id] { return chat }
    let chat = Chat()
    chatStore[id] = chat
    return chat
  }

  /// Read-only views of every chat, for actions and tests; a view observes `chat(_:)` instead.
  public var chats: [SessionID: ChatTranscript] { chatStore.compactMapValues(\.transcript) }
  public var historyStates: [SessionID: HistoryState] { chatStore.compactMapValues(\.history) }
  public var pendingPrompts: [SessionID: [PendingPrompt]] {
    chatStore.compactMapValues { $0.pending.isEmpty ? nil : $0.pending }
  }
  public var stopping: Set<SessionID> { Set(chatStore.filter(\.value.isStopping).keys) }

  public enum HistoryState: Equatable, Sendable {
    case loading
    /// Holds this many records (messages are only some of them); `hasOlder` says more are stored.
    case loaded(records: Int, hasOlder: Bool)
    case loadingOlder(records: Int)
    case failed(String)
  }

  /// Records per page; pages are read newest first and only as a conversation is scrolled back.
  static let historyPageSize = 50

  /// A message the phone sent that the agent has not recorded yet, shown at the end of its chat
  /// until the agent's own record of it arrives.
  public struct PendingPrompt: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
      /// On its way to the Mac.
      case sending
      /// The Mac took it; the agent will record it shortly.
      case sent
      /// The Mac took it while the agent was busy; it is answered after the current reply.
      case queued
      /// The Mac has not said whether it took it. It is sent again with the same commandId, which
      /// the Mac takes at most once, until it says (RFD0024).
      case uncertain
      /// The chat's Pi is starting and took nothing yet; it is sent again, with the same
      /// commandId, until Pi takes it (RFD0033).
      case waitingForPi
    }

    /// Its commandId: its receipt in the log retires it.
    public let id: UUID
    public let text: String
    /// Files already in the account, fetched by the Mac before Pi gets the prompt (RFD0030).
    public var attachments: [Attachment] = []
    /// When a working Pi takes it (RFD0033).
    public var delivery: PromptDelivery = .followUp
    public fileprivate(set) var state: State
    /// Sent while the agent was busy: it waits behind the reply being written, and shows below
    /// it; otherwise it starts the next reply, and shows above it.
    public var behindReply = false

    /// Its row in the conversation, the same as its record's once that arrives, so the row the
    /// screen holds its place by does not vanish under the reader.
    public var key: String { Self.key(commandId: id.uuidString.lowercased()) }
    public static func key(commandId: String) -> String { "prompt:\(commandId)" }

    init(
      id: UUID, text: String, attachments: [Attachment] = [], delivery: PromptDelivery = .followUp, state: State,
      behindReply: Bool = false
    ) {
      self.id = id
      self.text = text
      self.attachments = attachments
      self.delivery = delivery
      self.state = state
      self.behindReply = behindReply
    }
  }

  /// A restart of a chat's Pi, asked for from this phone.
  public enum Restart: Equatable, Sendable {
    /// The Mac said it is restarting Pi; the chat has not stopped being ready yet.
    case asked
    /// The chat's Pi is gone or starting: ready again means it is done.
    case underway
  }

  /// How long a restart waits for the chat to stop being ready before it counts as done: a Pi
  /// restarted in a moment may never be listed as anything else.
  @ObservationIgnored var restartGrace: Duration = .seconds(20)

  /// Whether the account's socket is up.
  public enum Link: Equatable, Sendable {
    /// Not started yet.
    case idle
    case connected
    /// The connection dropped; trying again, with growing pauses.
    case reconnecting
    /// The app is in the background: no connection on purpose.
    case suspended
  }
  /// The account socket's state, as `PhoneWorkbench` sees it.
  public internal(set) var link: Link = .idle
  /// The Mac's Workspaces as last read, so the menu can show the ones with no chats yet.
  public private(set) var workspaceList: [RemoteWorkspace] = []

  /// The chat on screen. Nothing selects one on its own: the person (or a new chat) does.
  public var selectedSessionID: SessionID?
  /// The last problem, for the screen to show; cleared by the next successful action.
  public private(set) var failure: String?

  private let connection: HostConnection
  private let feed: any ChatFeed
  private let account: AccountSession
  /// The chat open on the socket: its new records arrive as they are written.
  private var opened: SessionID?
  /// Chats started here that the host has not listed yet: kept until it does.
  private var created: [SessionID: RemoteSession] = [:]
  /// The next try of each uncertain message, by its commandId.
  @ObservationIgnored private var retries: [UUID: Task<Void, Never>] = [:]
  /// How long an uncertain message waits before it is sent again, and how often it is.
  nonisolated static let retryDelay: Duration = .seconds(3)
  nonisolated static let maxRetries = 40
  @ObservationIgnored var retryDelay: Duration = HostWorkbenchModel.retryDelay

  public init(host: RemoteHost, connection: HostConnection, feed: any ChatFeed, account: AccountSession) {
    hostLabel = host.label
    reference = host.reference
    status = host.status
    sessions = host.sessions.sorted(by: RemoteSession.isCreatedBefore)
    self.connection = connection
    self.feed = feed
    self.account = account
  }

  public var selectedSession: RemoteSession? {
    sessions.first { $0.sessionId == selectedSessionID }
  }

  /// Reads the Mac's Workspaces for the menu; a failure leaves the last list and says nothing.
  public func refreshWorkspaces() async {
    if let found = try? await connection.workspaces() { workspaceList = found }
  }

  /// The account's socket connected again: the open chat reads on from what it holds, the others
  /// will when opened, and the Workspaces are read again.
  func reconnected() async {
    Task { await refreshWorkspaces() }
    let reopen = opened
    opened = nil
    if let reopen { await loadHistory(of: reopen) }
  }

  /// Lets go of the open chat on the socket.
  func stop() {
    if let opened { Task { [feed] in await feed.close(opened) } }
    opened = nil
  }

  /// The account's listing of this Mac: its Sessions as listed replace what was known.
  public func adopt(listing host: RemoteHost) {
    guard host.reference == reference else { return }
    status = host.status
    if hostLabel != host.label { hostLabel = host.label }
    for listed in host.sessions {
      created[listed.sessionId] = nil
      if sessions.first(where: { $0.sessionId == listed.sessionId })?.pi != listed.pi { chatStore[listed.sessionId]?.chosen = nil }
    }
    sessions = (host.sessions + created.values).sorted(by: RemoteSession.isCreatedBefore)
    settleChats()
    if let selected = selectedSessionID, !sessions.contains(where: { $0.sessionId == selected }),
      chatStore[selected]?.pending.isEmpty ?? true
    {
      selectedSessionID = nil
    }
  }

  /// Sessions of this Mac that changed (listed, renamed, moved on, archived).
  func update(_ changed: [RemoteSession]) {
    for session in changed where session.hostId == reference.hostId {
      if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
        // What Pi runs is now as the Mac says, whatever was picked here.
        if sessions[index].pi != session.pi { chatStore[session.sessionId]?.chosen = nil }
        sessions[index] = session
      } else {
        sessions.append(session)
        sessions.sort(by: RemoteSession.isCreatedBefore)
      }
    }
    settleChats()
  }

  /// Whether the agent is working comes from the host's listing of each Session.
  private func settleChats() {
    for session in sessions {
      if let chat = chatStore[session.sessionId], let restart = chat.restart, let status = session.status {
        switch (restart, status) {
        case (_, .starting), (_, .unavailable): chat.restart = .underway
        case (.underway, _): chat.restart = nil
        case (.asked, _): break
        }
      }
      guard let status = session.status, let chat = chatStore[session.sessionId], chat.transcript != nil else { continue }
      let working = status == .working
      if (chat.transcript?.activity == .working) != working { chat.transcript?.settle(working: working) }
      if !working, chat.isStopping { chat.isStopping = false }
    }
  }

  // MARK: - Records

  /// Whether this Mac holds `id`.
  func holds(_ id: SessionID) -> Bool { sessions.contains { $0.sessionId == id } || chatStore[id] != nil }

  /// The next records of the open chat; the batch is acknowledged once taken.
  func receive(records: [ClientRecord], epoch: Int64, cursor: Int64, in id: SessionID) {
    defer { Task { [feed] in await feed.acknowledge(id, cursor: cursor) } }
    guard opened == id, let chat = chatStore[id], let transcript = chat.transcript else { return }
    if let held = chat.epoch, held != epoch { return }
    chat.epoch = epoch
    if let first = records.first, first.cursor > transcript.lastCursor + 1 {
      // A batch that does not follow what is held: open again from what is held.
      Task { await loadHistory(of: id) }
      return
    }
    changeChat(id) { $0.append(records) }
    showHistoryState(of: id)
  }

  func receive(progress slot: String, snapshot: JSONValue, in id: SessionID) {
    guard chatStore[id]?.transcript != nil else { return }
    changeChat(id) { $0.progress(slot: slot, snapshot: snapshot) }
  }

  /// The cloud copy was cut back: what came after `keep` goes.
  func receive(resetTo keep: Int64, epoch: Int64, in id: SessionID) {
    guard let chat = chatStore[id], chat.transcript != nil else { return }
    chat.epoch = epoch
    let first = chat.transcript?.firstCursor
    chat.transcript?.cut(keep: keep)
    // A cut below everything held leaves the records before it to be read as older history.
    if chat.transcript?.firstCursor == nil, first != nil { chat.older = keep > 0 ? keep + 1 : nil }
    showHistoryState(of: id)
  }

  #if DEBUG
    /// For the simulator preview only: records, progress and status as if the Mac had sent them.
    public func playForPreview(_ steps: [PreviewStep], in id: SessionID) {
      for step in steps {
        switch step {
        case .record(let message):
          let cursor = (chat(id).transcript?.lastCursor ?? 0) + 1
          let line = #"{"type":"message","id":"preview-\#(cursor)","message":\#(message)}"#
          changeChat(id) { $0.append([ClientRecord(cursor: cursor, id: "preview-\(cursor)", line: line)]) }
        case .progress(let slot, let json):
          let snapshot = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null
          changeChat(id) { $0.progress(slot: slot, snapshot: snapshot) }
        case .working(let working):
          changeChat(id) { $0.settle(working: working) }
        }
      }
    }

    /// For the simulator preview only: as if a stop had been asked for.
    public func markStoppingForPreview(_ id: SessionID) { chat(id).isStopping = true }
  #endif

  /// Opens a chat on the socket: from what is held when something is, or else its newest page.
  /// Its new records then arrive as they are written. The chat open before is let go.
  public func loadHistory(of id: SessionID) async {
    let chat = chat(id)
    if case .loading = chat.history { return }
    if case .loadingOlder = chat.history { return }
    if let previous = opened, previous != id { Task { [feed] in await feed.close(previous) } }
    opened = id
    let held = chat.transcript.flatMap { transcript in chat.epoch.map { (epoch: $0, cursor: transcript.lastCursor) } }
    if held == nil { chat.history = .loading }
    do {
      let result = try await feed.open(id, on: reference.hostId, have: held, window: Self.historyPageSize)
      guard opened == id else { return }
      if held == nil {
        // Parsed away from the main actor: Markdown and pictures take milliseconds a page.
        let parsed = await Self.parse(result.records)
        chat.older = result.older
        changeChat(id) { $0 = parsed }
      } else {
        changeChat(id) { $0.append(result.records) }
      }
      chat.epoch = result.epoch
      changeChat(id) { transcript in
        for progress in result.progress { transcript.progress(slot: progress.slot, snapshot: progress.snapshot) }
      }
      settleChats()
      showHistoryState(of: id)
    } catch is CancellationError {
      if held == nil { chat.history = nil }
    } catch {
      account.noteFailure(error)
      if opened == id { opened = nil }
      chat.history = .failed(error.localizedDescription)
    }
  }

  /// Opens `id` on the socket unless it is open already.
  func follow(_ id: SessionID) async {
    guard opened != id else { return }
    await loadHistory(of: id)
  }

  /// Reads the page before the oldest one already shown. Does nothing when there is none.
  public func loadOlderHistory(of id: SessionID) async {
    let chat = chat(id)
    guard case .loaded(let records, true) = chat.history, let before = chat.older else { return }
    chat.history = .loadingOlder(records: records)
    do {
      let page = try await feed.older(id, before: before, limit: Self.historyPageSize)
      if page.epoch == chat.epoch {
        let parsed = await Self.parse(page.records)
        chat.older = page.older
        changeChat(id) { $0.prepend(older: parsed) }
      }
      showHistoryState(of: id)
    } catch is CancellationError {
      chat.history = .loaded(records: records, hasOlder: true)
    } catch {
      account.noteFailure(error)
      chat.history = .loaded(records: records, hasOlder: true)
      failure = error.localizedDescription
    }
  }

  private func showHistoryState(of id: SessionID) {
    guard let chat = chatStore[id], chat.transcript != nil || chat.history != nil else { return }
    if case .loading = chat.history, chat.transcript == nil { return }
    chat.history = .loaded(records: chat.transcript?.records.count ?? 0, hasOlder: chat.older != nil)
  }

  /// Parses records away from the main actor.
  nonisolated private static func parse(_ records: [ClientRecord]) async -> ChatTranscript {
    await Task.detached(priority: .userInitiated) { ChatTranscript(records: records) }.value
  }

  // MARK: - Actions

  /// Starts a chat in `place` and opens it. A chat is a Session in a Workspace, running the agent
  /// in the Workspace's directory; every Mac has a Home Workspace, its home folder, which is
  /// where a chat goes unless it is started somewhere else.
  public func createChat(in place: NewChatPlace) async {
    await attempt {
      let session =
        switch place {
        case .home: try await connection.createSession()
        case .workspace(let workspace): try await connection.createSession(inWorkspace: workspace)
        }
      created[session.sessionId] = session
      update([session])
      selectedSessionID = session.sessionId
      // A new chat holds nothing yet: open it, so what the agent writes arrives.
      chat(session.sessionId).history = .loaded(records: 0, hasOlder: false)
      Task { await loadHistory(of: session.sessionId) }
    }
  }

  public func closeSession(_ id: SessionID) async {
    await attempt {
      let replacement = try await connection.closeSession(id)
      sessions.removeAll { $0.sessionId == id }
      chatStore[id] = nil
      if selectedSessionID == id { selectedSessionID = nil }
      if opened == id { stop() }
      if let replacement { update([replacement]) }
    }
  }

  public func renameSession(_ id: SessionID, to name: String) async {
    await attempt { try await connection.renameSession(id, to: name) }
  }

  /// How sending a message went.
  public enum PromptOutcome: Equatable, Sendable {
    case accepted
    /// Not sent (or refused): nothing reached Pi, so the words can go back in the box.
    case notSent
    /// The Mac has not said whether it took it, or its Pi is still starting: the message stays and
    /// is sent again.
    case uncertain
  }

  /// Sends a message to the selected chat, with its commandId. It shows as pending until the log
  /// holds it, queued or delivered; one refused on its first try disappears. `delivery` says when
  /// a working Pi takes it (RFD0033).
  public func sendPrompt(_ text: String, attachments: [Attachment] = [], delivery: PromptDelivery = .followUp) async
    -> PromptOutcome
  {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let session = selectedSession, !prompt.isEmpty || !attachments.isEmpty else { return .notSent }
    let id = session.sessionId
    let busy = chat(id).transcript?.activity == .working
    let pending = PendingPrompt(
      id: UUID(), text: prompt, attachments: attachments, delivery: delivery, state: .sending, behindReply: busy)
    chat(id).pending.append(pending)
    let outcome = await deliver(pending, in: id, attempt: 0)
    if outcome == .notSent { removePending(pending.id, in: id) }
    return outcome
  }

  /// One try at sending a pending message; an unknown outcome schedules the next.
  private func deliver(_ pending: PendingPrompt, in id: SessionID, attempt: Int) async -> PromptOutcome {
    let outcome: PromptOutcome
    var starting = false
    do {
      try await connection.promptPi(
        in: id, text: pending.text, commandId: pending.id, attachments: pending.attachments, delivery: pending.delivery)
      failure = nil
      outcome = .accepted
    } catch is CancellationError {
      outcome = attempt == 0 ? .notSent : .uncertain
    } catch AxoClientError.serverRejected(PiControlError.starting, _) {
      // Pi kept nothing and takes it once it is up: the same commandId again, until it does.
      starting = true
      outcome = .uncertain
    } catch {
      account.noteFailure(error)
      // A refusal after an unknown outcome proves nothing: the first try may still land.
      let unknown = Self.deliveryUncertain(error) || (attempt > 0 && Self.isHostOffline(error))
      outcome = unknown ? .uncertain : .notSent
      failure = unknown
        ? "\(hostLabel) has not said whether it got your message; trying again."
        : Self.notSentReason(error, host: hostLabel)
    }
    guard let chat = chatStore[id], let index = chat.pending.firstIndex(where: { $0.id == pending.id })
    else { return outcome }
    switch outcome {
    case .accepted:
      // Busy when it was sent, not when the Mac answered: by then the agent may be working on
      // this very message.
      chat.pending[index].state = pending.behindReply ? .queued : .sent
    case .uncertain:
      chat.pending[index].state = starting ? .waitingForPi : .uncertain
      if attempt < Self.maxRetries { scheduleRetry(of: pending, in: id, attempt: attempt + 1) }
    case .notSent:
      // A later try refused for another reason: shown, and left for the person to remove.
      if attempt > 0 { chat.pending[index].state = .uncertain }
    }
    return outcome
  }

  private func scheduleRetry(of pending: PendingPrompt, in id: SessionID, attempt: Int) {
    retries[pending.id]?.cancel()
    let delay = retryDelay
    retries[pending.id] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled else { return }
      self.retries[pending.id] = nil
      guard self.chatStore[id]?.pending.contains(where: { $0.id == pending.id }) == true else { return }
      _ = await self.deliver(pending, in: id, attempt: attempt)
    }
  }

  /// Takes a message marked uncertain off the screen, once the person has checked.
  public func dismissPending(_ pendingID: UUID, in id: SessionID) {
    removePending(pendingID, in: id)
  }

  private func removePending(_ pendingID: UUID, in id: SessionID) {
    retries.removeValue(forKey: pendingID)?.cancel()
    chatStore[id]?.pending.removeAll { $0.id == pendingID }
  }

  static func isHostOffline(_ error: Error) -> Bool {
    if case .serverRejected(Self.hostOffline, _) = error as? AxoClientError { return true }
    return false
  }

  /// Whether the request may have reached the Mac although no answer came back: it was written
  /// and then the connection ended, timed out, or the relay could not tell what happened.
  static func deliveryUncertain(_ error: Error) -> Bool {
    switch error as? AxoClientError {
    case .connectionClosed, .requestTimedOut: true
    // The relay's own "it went to the Mac, no answer came back" (axod's -32004 is "not found").
    case .serverRejected(let code, let message): code == -32004 && message.contains("reconcile")
    default: false
    }
  }

  /// The relay's "the Mac is offline; nothing was queued" (RFD0018).
  static let hostOffline = -32005

  static func notSentReason(_ error: Error, host: String) -> String {
    switch error as? AxoClientError {
    case .connectionFailed:
      "Not sent: no connection to \(host). Your message is still in the box."
    case .serverRejected(HostWorkbenchModel.hostOffline, _):
      "Not sent: \(host) is offline. Your message is still in the box."
    case .serverRejected(_, let message):
      "Not sent: \(message)"
    default:
      "Not sent: \(error.localizedDescription)"
    }
  }

  /// Stops the turn the chat shows running, named by what the phone saw of it (RFD0024): its
  /// newest user message when the pages held have one, the newest record held (a long run's
  /// newest page may hold only its tools), and the messages sent here not recorded yet (a stop
  /// right after Send). A turn that started after it, by the time the stop arrives, carries on.
  /// One the Mac says ran nothing it names leaves the chat not stopping, so a tap can try again.
  public func stopReply(in id: SessionID) async {
    let chat = chat(id)
    guard let transcript = chat.transcript, transcript.activity == .working, !chat.isStopping else { return }
    let turnId = transcript.lastUserEntry
    let seen = transcript.records.last?.id
    let commandIds = chat.pending.suffix(32).map { $0.id.uuidString.lowercased() }
    guard turnId != nil || seen != nil || !commandIds.isEmpty else { return }
    chat.isStopping = true
    var stopped = false
    await attempt {
      do {
        stopped = try await connection.stopPiTurn(in: id, turnId: turnId, seen: seen, commandIds: commandIds)
      } catch AxoClientError.serverRejected(Self.invalidParams, _) where turnId != nil {
        // A Mac from before 0.28 knows only turnId.
        stopped = try await connection.stopPiTurn(in: id, turnId: turnId)
      }
    }
    if !stopped { chat.isStopping = false }
  }

  /// JSON-RPC's invalid params: how a Mac refuses fields it doesn't know yet.
  static let invalidParams = -32602

  // MARK: - Pi's controls (RFD0033)

  /// Restarts the chat's Pi on its conversation, stopping a reply it is writing. The chat shows
  /// it restarting until it is ready again.
  public func restartPi(in id: SessionID) async {
    let chat = chat(id)
    guard chat.restart == nil else { return }
    chat.restart = .asked
    var asked = false
    await attempt {
      try await connection.restartPi(in: id)
      asked = true
    }
    guard asked else {
      chat.restart = nil
      return
    }
    settleChats()
    // A Pi back before its chat was listed as anything but ready has restarted already.
    let grace = restartGrace
    Task { [weak self] in
      try? await Task.sleep(for: grace)
      guard let self, let chat = self.chatStore[id], chat.restart == .asked else { return }
      chat.restart = nil
    }
  }

  /// Reads the slash commands the chat's Pi takes. The last list read stays when this fails.
  @discardableResult
  public func loadCommands(in id: SessionID) async -> [PiCommand]? {
    do {
      let commands = try await connection.piCommands(in: id)
      chat(id).commands = commands
    } catch is CancellationError {
    } catch {
      account.noteFailure(error)
    }
    return chatStore[id]?.commands
  }

  /// Reads the models the chat's Pi could switch to. The last list read stays when this fails.
  @discardableResult
  public func loadModels(in id: SessionID) async -> [PiModel]? {
    do {
      let models = try await connection.piModels(in: id)
      chat(id).models = models
    } catch is CancellationError {
    } catch {
      account.noteFailure(error)
      failure = Self.controlFailure(error)
    }
    return chatStore[id]?.models
  }

  /// What the chat's Pi runs: what was just picked here, until its listing says.
  public func piRuntime(of id: SessionID) -> PiRuntime? {
    chatStore[id]?.chosen ?? sessions.first { $0.sessionId == id }?.pi
  }

  /// Switches the chat's model, thinking level, or both, for this chat only. Shown at once; the
  /// chat's listing then says what Pi runs.
  public func setModel(_ model: PiModel? = nil, thinkingLevel: ThinkingLevel? = nil, in id: SessionID) async {
    guard model != nil || thinkingLevel != nil else { return }
    let before = piRuntime(of: id)
    let ref = model.map { PiModelRef(provider: $0.provider, id: $0.id, name: $0.name) }
    var level = thinkingLevel ?? before?.thinkingLevel
    // Pi moves a level the new model lacks to one it has; until it says which, none is shown.
    if let model, let current = level, !model.thinkingLevels.contains(current) { level = nil }
    let chat = chat(id)
    chat.chosen = PiRuntime(model: ref ?? before?.model, thinkingLevel: level)
    do {
      try await connection.setPiModel(in: id, model: ref, thinkingLevel: thinkingLevel)
      failure = nil
    } catch is CancellationError {
      chat.chosen = nil
    } catch {
      account.noteFailure(error)
      chat.chosen = nil
      failure = Self.controlFailure(error)
    }
  }

  static func controlFailure(_ error: Error) -> String {
    switch error as? AxoClientError {
    case .serverRejected(PiControlError.notSignedIn, _): "Pi isn't signed in to that model's provider on the Mac."
    case .serverRejected(_, let message): message
    default: error.localizedDescription
    }
  }

  /// An answer to what Pi is asking.
  public enum Answer: Equatable, Sendable {
    case yes
    case no
    case text(String)
  }

  /// Answers Pi's question in `id`: yes is Enter, no is Escape, and words are sent as a prompt is.
  /// The question stays on screen until its progress slot is cleared.
  public func answer(_ answer: Answer, in id: SessionID) async {
    guard chatStore[id]?.transcript?.question != nil else { return }
    await attempt {
      switch answer {
      case .yes: try await connection.pressPiKey(.enter, in: id)
      case .no: try await connection.pressPiKey(.escape, in: id)
      case .text(let words): try await connection.promptPi(in: id, text: words, commandId: UUID())
      }
    }
  }

  /// Changes a chat, then retires the pending messages the log now holds: the ones whose receipt,
  /// written by the Mac just before their user message, carries their commandId (RFD0024).
  private func changeChat(_ id: SessionID, _ change: (inout ChatTranscript) -> Void) {
    let chat = chat(id)
    // Changed where it is: a copy taken out and put back would copy every message, every event.
    if chat.transcript == nil { chat.transcript = ChatTranscript() }
    change(&chat.transcript!)
    if chat.transcript?.activity == .idle, chat.isStopping { chat.isStopping = false }
    guard !chat.pending.isEmpty, let transcript = chat.transcript else { return }
    // Queued in the log is as good as delivered: the log shows it from here on (RFD0033).
    let held = transcript.delivered.union(transcript.queued.map(\.commandId))
    guard !held.isEmpty else { return }
    let landed = chat.pending.filter { held.contains($0.id.uuidString.lowercased()) }
    guard !landed.isEmpty else { return }
    for prompt in landed { retries.removeValue(forKey: prompt.id)?.cancel() }
    chat.pending.removeAll { held.contains($0.id.uuidString.lowercased()) }
  }

  /// Shows `message` where failures are shown.
  func report(_ message: String) { failure = message }

  private func attempt(_ work: () async throws -> Void) async {
    do {
      try await work()
      failure = nil
    } catch is CancellationError {
    } catch {
      fail(error)
    }
  }

  private func fail(_ error: Error) {
    account.noteFailure(error)
    failure = error.localizedDescription
  }
}

extension RemoteSession {
  /// The order a Mac's Sessions are kept in: oldest first, as Axod lists them. Session IDs carry
  /// no order, so they only break ties.
  static func isCreatedBefore(_ a: RemoteSession, _ b: RemoteSession) -> Bool {
    if a.createdAt != b.createdAt { return (a.createdAt ?? 0) < (b.createdAt ?? 0) }
    return a.sessionId.rawValue < b.sessionId.rawValue
  }
}

#if DEBUG
  /// One thing the simulator preview plays into a chat.
  public enum PreviewStep: Sendable {
    /// A message entry's `message`, as JSON.
    case record(String)
    /// A progress slot's snapshot, as JSON (`null` clears it).
    case progress(String, String)
    case working(Bool)
  }
#endif
