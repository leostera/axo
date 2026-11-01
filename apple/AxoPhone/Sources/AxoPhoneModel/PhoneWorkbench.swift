import AxoClient
import AxoProtocol
import Foundation
import Observation

/// The account's socket, as the phone needs it (`AccountConnection`; a stand-in in tests).
public protocol AccountFeed: ChatFeed {
  var events: AsyncStream<AccountEvent> { get }
  var connectionLost: AsyncStream<Void> { get }
  func connect() async throws
  func disconnect() async
  func refresh() async throws -> ClientHello
}

extension AccountConnection: AccountFeed {}

/// Everything the phone shows: the account's Macs, and the one open Session on one of them.
///
/// One socket follows the whole account (RFD0018): every Mac and chat is listed and kept current,
/// and the chat on screen is open, so its records arrive as they are written. A Mac that is
/// offline can still be read (its conversations are in the cloud), it just cannot be typed into.
@MainActor
@Observable
public final class PhoneWorkbench {
  public struct Selection: Hashable, Sendable {
    public let host: UUID
    public let session: SessionID?

    public init(host: UUID, session: SessionID?) {
      self.host = host
      self.session = session
    }
  }

  public let hosts: HostsModel
  public private(set) var selection: Selection?
  /// The open Mac, if any.
  public private(set) var current: HostWorkbenchModel?
  /// Whether the account's socket is up.
  public private(set) var link: HostWorkbenchModel.Link = .idle {
    didSet { current?.link = link }
  }

  /// What is typed in each chat's box, kept while other chats are open. A new chat's is keyed by
  /// its Mac with no Session.
  private var drafts: [Selection: String] = [:]
  /// A message is on its way; a second tap must not start a second chat.
  public private(set) var isSending = false

  private let feed: any AccountFeed
  private let account: AccountSession
  private let makeWorkbench: @MainActor (RemoteHost) -> HostWorkbenchModel
  /// Pauses between reconnection attempts; tests make them short.
  private let reconnectDelays: [Duration]
  private var started = false
  private var eventTask: Task<Void, Never>?
  private var lossTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?

  public init(
    hosts: HostsModel, feed: any AccountFeed, account: AccountSession,
    reconnectDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(5), .seconds(15)],
    makeWorkbench: @escaping @MainActor (RemoteHost) -> HostWorkbenchModel
  ) {
    self.hosts = hosts
    self.feed = feed
    self.account = account
    self.reconnectDelays = reconnectDelays
    self.makeWorkbench = makeWorkbench
  }

  /// Follows the account's socket, and lands on a new chat, ready to be typed into, on the first
  /// Mac that is online (or the first there is). A chat only comes to exist when its first message
  /// is sent.
  public func start() async {
    guard !started else { return }
    started = true
    let events = feed.events
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.apply(event)
      }
    }
    let losses = feed.connectionLost
    lossTask = Task { [weak self] in
      for await _ in losses {
        guard let self else { return }
        if self.link == .connected { self.reconnect() }
      }
    }
    hosts.loading()
    do {
      try await feed.connect()
    } catch {
      if account.noteFailure(error) { return }
      hosts.failed(error.localizedDescription)
      reconnect()
    }
  }

  // MARK: - The account's socket

  private func apply(_ event: AccountEvent) async {
    switch event {
    case .hello(let listing) where suspended:
      // A call made on the way to the background connected again: take the news, let it go.
      hosts.adopt(listing)
      listingChanged()
      await feed.disconnect()
    case .hello(let listing):
      link = .connected
      reconnectTask?.cancel()
      reconnectTask = nil
      hosts.adopt(listing)
      listingChanged()
      if selection == nil { beginNewChat() }
      await current?.reconnected()
    case .hosts(let listed):
      hosts.update(hosts: listed)
      listingChanged()
    case .sessions(let host, let changed):
      hosts.update(sessions: changed, of: host)
      listingChanged()
    case .records(let id, let epoch, let records, let cursor):
      if let current, current.holds(id) {
        current.receive(records: records, epoch: epoch, cursor: cursor, in: id)
      } else {
        await feed.acknowledge(id, cursor: cursor)
      }
    case .progress(let id, let slot, let snapshot):
      current?.receive(progress: slot, snapshot: snapshot, in: id)
    case .reset(let id, let epoch, let keep):
      current?.receive(resetTo: keep, epoch: epoch, in: id)
    }
  }

  /// The listing moved: the open Mac takes its part, a Mac that came back as a new run is opened
  /// afresh, and a Mac that left the account closes.
  private func listingChanged() {
    guard let current, let selection else { return }
    guard let listed = hosts.hosts.first(where: { $0.hostId == current.reference.hostId }) else {
      if hosts.phase == .loaded { close() }
      return
    }
    if listed.hostGeneration == current.reference.hostGeneration {
      current.adopt(listing: listed)
    } else {
      // The Mac restarted: its commands must name the new run. Open it again, on the same chat.
      current.stop()
      self.current = nil
      select(host: selection.host, session: selection.session)
    }
  }

  /// Connects again until it works, with growing pauses. The hello that follows lists what
  /// changed meanwhile, and the open chat reads on from what it holds.
  private func reconnect() {
    link = .reconnecting
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self, feed, reconnectDelays] in
      var attempt = 0
      while !Task.isCancelled {
        do {
          try await feed.connect()
          return
        } catch is CancellationError {
          return
        } catch {
          if let self, self.account.noteFailure(error) { return }
          let delay = reconnectDelays[min(attempt, reconnectDelays.count - 1)]
          attempt += 1
          try? await Task.sleep(for: delay)
        }
      }
    }
  }

  /// The app is in the background and has let the socket go.
  private var suspended = false

  /// The app went to the background: let the socket go rather than have it die unnoticed.
  public func suspend() {
    guard started, link != .suspended else { return }
    suspended = true
    reconnectTask?.cancel()
    reconnectTask = nil
    link = .suspended
    Task { [feed] in await feed.disconnect() }
  }

  /// The app is active again (from the background, or just from a passing alert, which needs
  /// nothing): the socket connects again and its hello catches everything up.
  public func resume() async {
    guard suspended else { return }
    suspended = false
    reconnect()
  }

  /// Lists the account's Macs and chats again now: for a Mac paired a moment ago, or a pull.
  public func refresh() async {
    do {
      hosts.adopt(try await feed.refresh())
      listingChanged()
      if selection == nil { beginNewChat() }
    } catch {
      account.noteFailure(error)
    }
  }

  /// Whether the screen is on a new chat that does not exist yet.
  public var isDrafting: Bool { selection != nil && selection?.session == nil }

  /// Goes to a blank new chat on the open Mac (or the first online one). Nothing is created.
  public func beginNewChat() {
    guard let host = newChatHost ?? hosts.hosts.first else { return }
    select(host: host.hostId, session: nil)
  }

  public func select(host hostID: UUID, session: SessionID?) {
    guard let remote = hosts.hosts.first(where: { $0.hostId == hostID }) else { return }
    if current?.reference.hostId != hostID {
      current?.stop()
      let workbench = makeWorkbench(remote)
      workbench.link = link
      current = workbench
      Task { await workbench.refreshWorkspaces() }
    }
    selection = Selection(host: hostID, session: session)
    guard let workbench = current else { return }
    workbench.selectedSessionID = session
    if let session { Task { await workbench.follow(session) } } else { workbench.stop() }
  }

  /// Whether the person can choose the Mac the open chat starts on: it is a new chat, and there is
  /// more than one Mac to choose from.
  public var canChooseHost: Bool { isDrafting && hosts.hosts.count > 1 }

  /// The Mac a new chat starts on, chosen by the message box: what is typed comes along, and the
  /// chat goes back to that Mac's Home Workspace, since Workspaces are a Mac's own. Only a new chat
  /// can move, and only to another Mac of the account that is online.
  public func chooseHost(_ hostID: UUID) {
    guard let draft = selection, draft.session == nil, draft.host != hostID,
      hosts.hosts.contains(where: { $0.hostId == hostID && $0.status == .online })
    else { return }
    let text = self.draft(for: draft)
    setDraft("", for: draft)
    select(host: hostID, session: nil)
    if !text.isEmpty { setDraft(text, for: Selection(host: hostID, session: nil)) }
  }

  /// The Mac a new chat goes to: the open one if it is online, else the first Mac that is.
  public var newChatHost: RemoteHost? {
    if let current, current.status == .online,
      let open = hosts.hosts.first(where: { $0.hostId == current.reference.hostId })
    {
      return open
    }
    return hosts.hosts.first { $0.status == .online }
  }

  // MARK: - Drafts and sending

  public func draft(for selection: Selection) -> String { drafts[selection] ?? "" }

  public func setDraft(_ text: String, for selection: Selection) {
    drafts[selection] = text.isEmpty ? nil : text
  }

  /// How sending went.
  public enum SendOutcome: Equatable, Sendable {
    /// The Mac took the message (for a new chat: the chat exists, is open, and took it).
    case sent
    /// Nothing was sent; the reason is in `current?.failure` and the words are back in the box.
    case failed
    /// The connection dropped while sending: the message may have arrived. It shows as
    /// uncertain in the chat and its words do not come back, so it is not sent twice by mistake.
    case uncertain
  }

  /// Sends what is typed in the open chat. On a new chat, the first message brings the chat into
  /// being in the Mac's Home Workspace. The words leave the box as they go and come back if the
  /// Mac refuses them.
  public func send() async -> SendOutcome {
    guard !isSending, let selection, !text(of: selection).isEmpty else { return .failed }
    isSending = true
    defer { isSending = false }
    guard selection.session != nil else { return await startChat(in: .home, from: selection) }
    return await prompt(from: selection)
  }

  /// Starts the new chat in `place` with what is typed in it: how a chat starts somewhere other
  /// than Home.
  public func send(in place: NewChatPlace) async -> SendOutcome {
    guard !isSending, let selection, selection.session == nil, !text(of: selection).isEmpty else { return .failed }
    isSending = true
    defer { isSending = false }
    return await startChat(in: place, from: selection)
  }

  private func text(of selection: Selection) -> String {
    draft(for: selection).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func startChat(in place: NewChatPlace, from draft: Selection) async -> SendOutcome {
    guard let workbench = await openNewChatHost(for: draft) else { return .failed }
    await workbench.createChat(in: place)
    guard workbench.failure == nil, let id = workbench.selectedSessionID else { return .failed }
    // The words move to the chat they started; a refusal leaves them in its box.
    let chat = Selection(host: draft.host, session: id)
    setDraft(self.draft(for: draft), for: chat)
    setDraft("", for: draft)
    select(session: id)
    return await prompt(from: chat)
  }

  private func prompt(from selection: Selection) async -> SendOutcome {
    guard let workbench = current, workbench.reference.hostId == selection.host else { return .failed }
    let text = text(of: selection)
    setDraft("", for: selection)
    switch await workbench.sendPrompt(text) {
    case .accepted: return .sent
    case .uncertain: return .uncertain
    case .notSent:
      if draft(for: selection).isEmpty { setDraft(text, for: selection) }
      return .failed
    }
  }

  // MARK: - What the menu lists

  /// A Mac's Sessions as the menu should show them: the open Mac's include a chat just started
  /// there that the listing does not have yet.
  public func sessions(of host: RemoteHost) -> [RemoteSession] {
    if let current, current.reference.hostId == host.hostId { return current.sessions }
    return host.sessions
  }

  /// The Mac a new chat drafted on `draft.host` starts on: that one, which must be online.
  private func openNewChatHost(for draft: Selection) async -> HostWorkbenchModel? {
    guard let current, current.reference.hostId == draft.host else { return nil }
    guard current.status == .online else {
      current.report("\(current.hostLabel) is offline.")
      return nil
    }
    return current
  }

  /// Opens one of the open Mac's Sessions.
  public func select(session: SessionID) {
    guard let host = selection?.host else { return }
    select(host: host, session: session)
  }

  public func close() {
    current?.stop()
    current = nil
    selection = nil
  }

  /// Stops following the account: the socket goes.
  public func stop() {
    eventTask?.cancel()
    lossTask?.cancel()
    reconnectTask?.cancel()
    eventTask = nil
    lossTask = nil
    reconnectTask = nil
    started = false
    link = .idle
    Task { [feed] in await feed.disconnect() }
  }
}

/// Where a new chat starts on its Mac.
public enum NewChatPlace: Equatable, Hashable, Sendable {
  /// The Mac's Home Workspace (its home folder): where a chat goes unless it is told otherwise.
  case home
  /// One of the Mac's Workspaces, chosen by the person.
  case workspace(UUID)
}
