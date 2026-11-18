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
  func renameHost(_ host: UUID, to name: String) async throws -> String
  func resolveElicitation(
    _ id: String, on host: UUID, action: ElicitationAnswer, device: DeviceProof, sealed: SealedInput?) async throws
}

/// What a Mac's agent asks the person (RFD0029), until the Mac says it is settled.
public struct AskedQuestion: Identifiable, Equatable, Sendable {
  public let hostID: UUID
  public let elicitation: Elicitation
  /// This phone sent an answer and waits to hear it was taken.
  public internal(set) var answering: ElicitationAnswer?

  public var id: String { elicitation.id }
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
  /// Preferences never cross host generations; pending initialization stays with its created chat.
  private var draftModels: [RemoteHostRef: DraftModelChoice] = [:]
  private var initialModels: [Selection: DraftModelChoice] = [:]
  private struct DraftTarget: Hashable {
    let host: RemoteHostRef
    let place: NewChatPlace
  }
  private var preparedChats: [DraftTarget: RemoteSession] = [:]
  @ObservationIgnored private var navigationRevision = 0

  public func modelChoice(for destination: Selection) -> DraftModelChoice? {
    if destination.session != nil { return initialModels[destination] }
    guard let host = hosts.hosts.first(where: { $0.hostId == destination.host }) else { return nil }
    return draftModels[host.reference]
  }

  /// Picking changes intent only. Even Retry requires an explicit Send, never an automatic prompt.
  public func chooseModel(_ model: PiModel?, thinkingLevel: ThinkingLevel? = nil, for destination: Selection) {
    guard !isSending, selection == destination, let current else { return }
    let choice = model.flatMap { DraftModelChoice(model: $0, thinkingLevel: thinkingLevel) }
    guard model == nil || choice != nil else { return }
    if destination.session != nil {
      initialModels[destination] = choice
    } else {
      draftModels[current.reference] = choice
    }
  }
  /// What the Macs' agents ask now, oldest first (RFD0029).
  public private(set) var questions: [AskedQuestion] = []
  @ObservationIgnored private var settledQuestions: [String: Int64] = [:]
  private struct AnswerOperation {
    let destination: Selection
    let result: Task<Bool, Never>
  }
  @ObservationIgnored private var answersInFlight: [String: AnswerOperation] = [:]
  @ObservationIgnored private var protectedInteractions: Set<Selection> = []
  /// Why the last answer did not go, until the next one does.
  public private(set) var answerFailure: String?
  /// Each Mac's input key as first seen.
  public var inputKeyPins = InputKeyPins()
  /// This phone's key, which signs every answer; made on first use.
  public var device: (any DeviceSigner)?
  /// What a Mac shows when this phone first answers it.
  public var deviceName = "iPhone"
  /// A message is on its way; a second tap must not start a second chat.
  public private(set) var isSending = false
  /// The files in each chat's box (RFD0030), uploading or ready, kept like the words.
  private var draftFiles: [Selection: [DraftAttachment]] = [:]
  /// Original bytes stay only in memory until success or removal, so a failed upload can retry.
  @ObservationIgnored private var uploads: [UUID: DraftUpload] = [:]
  @ObservationIgnored var uploadRetryDelays: [Duration] = [.seconds(1), .seconds(3)]
  private struct DraftUpload: Sendable {
    let data: Data
    let name: String
    let mimeType: String
    var generation = UUID()
    var task: Task<Void, Never>?
  }
  /// Puts a file in the account's assets; what a prompt names it by.
  private let uploadAsset: @Sendable (Data, String, String) async throws -> Attachment

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
    uploadAsset: @escaping @Sendable (Data, String, String) async throws -> Attachment = { _, _, _ in
      throw AxoClientError.invalidResponse("attachments are unavailable here")
    },
    makeWorkbench: @escaping @MainActor (RemoteHost) -> HostWorkbenchModel
  ) {
    self.uploadAsset = uploadAsset
    self.hosts = hosts
    self.feed = feed
    self.account = account
    self.reconnectDelays = reconnectDelays
    self.makeWorkbench = makeWorkbench
  }

  deinit {
    for upload in uploads.values { upload.task?.cancel() }
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
        // What is still asked comes again with the next hello.
        self.questions.removeAll()
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
      for session in changed where session.status == .ready || session.status == .unavailable {
        let destination = Selection(host: host, session: session.sessionId)
        if !questions.contains(where: { $0.hostID == host && $0.elicitation.sessionId == session.sessionId })
          && !answersInFlight.values.contains(where: { $0.destination == destination }) {
          protectedInteractions.remove(destination)
        }
      }
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
    case .elicitationRequested(let host, let elicitation):
      let now = Date().timeIntervalSince1970 * 1_000
      settledQuestions = settledQuestions.filter { Double($0.value) > now }
      guard settledQuestions[elicitation.id] == nil else { break }
      protectedInteractions.insert(Selection(host: host, session: elicitation.sessionId))
      if !questions.contains(where: { $0.id == elicitation.id }) {
        questions.append(AskedQuestion(hostID: host, elicitation: elicitation))
      }
    case .elicitationResolved(_, let id, _):
      if let question = questions.first(where: { $0.id == id }) { settledQuestions[id] = question.elicitation.expiresAt }
      questions.removeAll { $0.id == id }
    }
  }

  // MARK: - What the agents ask

  #if DEBUG
    /// For the simulator preview only: a question as if a Mac had asked it.
    public func askForPreview(_ elicitation: Elicitation, host: UUID) {
      if !questions.contains(where: { $0.id == elicitation.id }) {
        questions.append(AskedQuestion(hostID: host, elicitation: elicitation))
      }
    }
  #endif

  /// What the agent of `session` asks now.
  public func questions(in session: SessionID) -> [AskedQuestion] {
    questions.filter { $0.elicitation.sessionId == session }
  }

  /// Answers what a Mac's agent asks. The card stays until the Mac says it is settled; an answer
  /// that came too late (another device answered, or it expired) removes it.
  public func answer(_ id: String, _ action: ElicitationAnswer, values: [String: String]? = nil) async {
    guard answersInFlight[id] == nil, let question = questions.first(where: { $0.id == id }),
      question.answering == nil else { return }
    let destination = Selection(host: question.hostID, session: question.elicitation.sessionId)
    protectedInteractions.insert(destination)
    let result = Task { await performAnswer(id, action, values: values) }
    answersInFlight[id] = AnswerOperation(destination: destination, result: result)
    _ = await result.value
    answersInFlight[id] = nil
  }

  private func performAnswer(_ id: String, _ action: ElicitationAnswer, values: [String: String]? = nil) async -> Bool {
    guard let index = questions.firstIndex(where: { $0.id == id }), questions[index].answering == nil else { return false }
    let host = questions[index].hostID
    var sealed: SealedInput?
    if let input = questions[index].elicitation.input, action == .accept {
      // The values leave the phone only sealed to the Mac's key, and only to the key first seen
      // for that Mac: a different one may be the cloud's, not the Mac's.
      guard inputKeyPins.check(host: host, key: input.key) != .changed else {
        answerFailure = "This Mac's encryption key changed. Nothing was sent; check the key in Axo on that Mac."
        return false
      }
      guard let values else { return false }
      do {
        sealed = try InputSeal.seal(values, to: input.key, requestID: id, origin: input.origin)
      } catch {
        answerFailure = "The values could not be encrypted for this Mac."
        return false
      }
    }
    let proof: DeviceProof
    do {
      let signer = try device ?? PhoneDeviceKey.stored()
      device = signer
      proof = try signer.prove(requestID: id, action: action, sealed: sealed, name: deviceName)
    } catch let error as PhoneDeviceKey.StorageError {
      answerFailure = error.localizedDescription
      return false
    } catch {
      answerFailure = "This device couldn’t sign the answer."
      return false
    }
    questions[index].answering = action
    do {
      try await feed.resolveElicitation(id, on: host, action: action, device: proof, sealed: sealed)
      answerFailure = nil
      return true
    } catch {
      if case AxoClientError.serverRejected(let code, _) = error, code == ElicitationError.notPending {
        questions.removeAll { $0.id == id }
        return true
      } else {
        if let again = questions.firstIndex(where: { $0.id == id }) { questions[again].answering = nil }
        answerFailure = error.localizedDescription
        return false
      }
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

  /// Names a Mac for the whole account: the network's name for it is rarely what anyone calls it.
  /// An empty name goes back to that. Returns why it could not, or nil once it is saved.
  public func renameHost(_ hostID: UUID, to name: String) async -> String? {
    guard link == .connected else { return "Not connected; try again in a moment." }
    do {
      let label = try await feed.renameHost(hostID, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
      hosts.renamed(hostID, to: label)
      listingChanged()
      return nil
    } catch {
      account.noteFailure(error)
      return "Could not rename the Mac: \(error.localizedDescription)"
    }
  }

  /// Whether the screen is on a new chat that does not exist yet.
  public var isDrafting: Bool { selection != nil && selection?.session == nil }

  /// Goes to a blank new chat on the open Mac (or the first online one). Nothing is created.
  public func beginNewChat() {
    guard let host = newChatHost ?? hosts.hosts.first else { return }
    select(host: host.hostId, session: nil)
  }

  /// Leave execution admission behind without losing selection or drafts. Already-dispatched
  /// commands cannot be recalled; a pending create/configuration acknowledgment cannot send later.
  public func retirePendingSend() {
    navigationRevision += 1
  }

  /// A notification is navigation, never execution authority. Resolve only a listed conversation
  /// in the live account; a removed host/session must not silently select an unrelated chat.
  public func openNotification(_ route: RequestNotificationRoute) async -> Bool {
    let revision = account.credentialRevision
    guard let token = try? await account.tokens.sessionToken(), token.accountID == route.accountID,
      let session = SessionID(rawValue: route.sessionID.uuidString.lowercased()) else { return false }
    func destinationExists() -> Bool {
      guard let host = hosts.hosts.first(where: { $0.hostId == route.hostID }) else { return false }
      return sessions(of: host).contains { $0.sessionId == session }
    }
    if !destinationExists() { await refresh() }
    guard account.credentialRevision == revision, destinationExists() else { return false }
    select(host: route.hostID, session: session)
    return true
  }

  public func select(host hostID: UUID, session: SessionID?) {
    guard let remote = hosts.hosts.first(where: { $0.hostId == hostID }) else { return }
    if current?.reference.hostId != hostID {
      current?.stop()
      let workbench = makeWorkbench(remote)
      workbench.link = link
      current = workbench
    }
    navigationRevision += 1
    selection = Selection(host: hostID, session: session)
    guard let workbench = current else { return }
    workbench.selectedSessionID = session
    if let session { Task { await workbench.follow(session) } } else { workbench.stop() }
  }

  /// Whether the person can choose the Mac the open chat starts on: it is a new chat, and there is
  /// more than one Mac to choose from.
  public var canChooseHost: Bool { isDrafting && hosts.hosts.count > 1 }

  /// The Mac a new chat starts on, chosen by the message box: what is typed comes along, and the
  /// chat starts in that Mac's home folder. Only a new chat
  /// can move, and only to another Mac of the account that is online.
  public func chooseHost(_ hostID: UUID) {
    guard let draft = selection, draft.session == nil, draft.host != hostID,
      hosts.hosts.contains(where: { $0.hostId == hostID && $0.status == .online })
    else { return }
    let text = self.draft(for: draft)
    let files = attachments(for: draft)
    setDraft("", for: draft)
    draftFiles[draft] = nil
    select(host: hostID, session: nil)
    if !text.isEmpty { setDraft(text, for: Selection(host: hostID, session: nil)) }
    if !files.isEmpty { draftFiles[Selection(host: hostID, session: nil)] = files }
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

  /// A file in a chat's box: uploading to the account, ready to send, or refused.
  public struct DraftAttachment: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
      case uploading
      case ready(Attachment)
      case failed(String)
    }

    public let id: UUID
    public let name: String
    public let mimeType: String
    public let size: Int
    /// A small picture of it, for an image.
    public let thumbnail: Data?
    public fileprivate(set) var state: State
    fileprivate let retryable: Bool

    public var canRetry: Bool {
      if case .failed = state { return retryable }
      return false
    }
  }

  public func attachments(for selection: Selection) -> [DraftAttachment] { draftFiles[selection] ?? [] }

  /// Puts files in the open chat's box and uploads each to the account at once.
  public func attach(_ files: [(data: Data, name: String, mimeType: String, thumbnail: Data?)]) {
    guard let selection else { return }
    let room = Attachment.maxPerPrompt - attachments(for: selection).count
    if files.count > room { current?.report("A message can carry at most \(Attachment.maxPerPrompt) files.") }
    for file in files.prefix(max(0, room)) {
      let tooLarge = file.data.count > Attachment.maxBytes
      let draft = DraftAttachment(
        id: UUID(), name: Attachment.safeName(file.name), mimeType: Attachment.storedType(file.mimeType),
        size: file.data.count, thumbnail: file.thumbnail,
        state: tooLarge ? .failed("Files can be at most 100 MB.") : .uploading, retryable: !tooLarge)
      draftFiles[selection, default: []].append(draft)
      guard !tooLarge else { continue }
      uploads[draft.id] = DraftUpload(data: file.data, name: draft.name, mimeType: draft.mimeType)
      startUpload(draft.id)
    }
  }

  /// Explicit retries start one new bounded batch, never a message or a reconnect outbox.
  public func retryUpload(_ id: UUID) {
    guard let selection, attachments(for: selection).contains(where: { $0.id == id && $0.canRetry }) else { return }
    startUpload(id)
  }

  private func attachmentLocation(_ id: UUID) -> (selection: Selection, index: Int)? {
    for (selection, files) in draftFiles {
      if let index = files.firstIndex(where: { $0.id == id }) { return (selection, index) }
    }
    return nil
  }

  private func startUpload(_ id: UUID) {
    guard var input = uploads[id], let location = attachmentLocation(id) else { return }
    input.task?.cancel()
    input.generation = UUID()
    let generation = input.generation
    let data = input.data, name = input.name, mimeType = input.mimeType
    let upload = uploadAsset, delays = uploadRetryDelays
    draftFiles[location.selection]?[location.index].state = .uploading
    input.task = Task { [weak self] in
      // AssetsClient uses a content-addressed PUT: retrying these same bytes is idempotent.
      for attempt in 0...delays.count {
        guard self?.uploads[id]?.generation == generation else { return }
        do {
          if attempt > 0 { try await Task.sleep(for: delays[attempt - 1]) }
          try Task.checkCancellation()
          let attachment = try await upload(data, name, mimeType)
          try Task.checkCancellation()
          self?.finishUpload(id, generation: generation, state: .ready(attachment))
          return
        } catch is CancellationError {
          if !Task.isCancelled {
            self?.finishUpload(id, generation: generation, state: .failed("Upload interrupted. Tap to retry."))
          }
          return
        } catch {
          guard !Task.isCancelled else { return }
          if attempt < delays.count, Self.shouldRetryUpload(error) { continue }
          self?.finishUpload(id, generation: generation, state: .failed(error.localizedDescription))
          return
        }
      }
    }
    uploads[id] = input
  }

  nonisolated private static func shouldRetryUpload(_ error: Error) -> Bool {
    if let refusal = error as? AppsRefusal {
      return refusal.status == 408 || (500...599).contains(refusal.status)
    }
    if let relay = error as? RelayError {
      switch relay {
      case .unreachable: return true
      case .httpStatus(let status): return status == 408 || (500...599).contains(status)
      case .signInRequired: return false
      }
    }
    if let client = error as? AxoClientError {
      switch client {
      case .connectionClosed, .connectionFailed, .requestTimedOut: return true
      default: return false
      }
    }
    if let error = error as? URLError {
      return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        .contains(error.code)
    }
    return false
  }

  private func finishUpload(_ id: UUID, generation: UUID, state: DraftAttachment.State) {
    guard uploads[id]?.generation == generation, let location = attachmentLocation(id) else { return }
    // Locate by attachment identity: choosing another host may have moved its draft while uploading.
    draftFiles[location.selection]?[location.index].state = state
    if case .ready = state { uploads[id] = nil }
    else { uploads[id]?.task = nil }
  }

  /// Takes a file out of the open chat's box; an uploaded one stays in the account.
  public func detach(_ id: UUID) {
    guard let selection else { return }
    guard attachments(for: selection).contains(where: { $0.id == id }) else { return }
    uploads[id]?.task?.cancel()
    uploads[id] = nil
    draftFiles[selection]?.removeAll { $0.id == id }
    if draftFiles[selection]?.isEmpty == true { draftFiles[selection] = nil }
  }

  /// Whether the open chat's box can go: words or files, and every file uploaded.
  public var canSendDraft: Bool {
    guard let selection else { return false }
    let files = attachments(for: selection)
    guard files.allSatisfy({ if case .ready = $0.state { true } else { false } }) else { return false }
    return !text(of: selection).isEmpty || !files.isEmpty
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
  /// being in the Mac's home folder. The words leave the box as they go and come back if the
  /// Mac refuses them. `delivery` says when a working Pi takes it (RFD0033): by default it
  /// interrupts, so the agent answers it now.
  public func send(delivery: PromptDelivery = .interrupt) async -> SendOutcome {
    guard !isSending, let selection, canSendDraft else { return .failed }
    isSending = true
    defer { isSending = false }
    guard selection.session != nil else { return await startChat(in: .home, from: selection) }
    let answers = answersInFlight.values.filter { $0.destination == selection }.map(\.result)
    for answer in answers {
      guard await answer.value else { return .failed }
    }
    // The box remains owned by its original chat while the answer is acknowledged.
    guard self.selection == selection else { return .failed }
    let protected = protectedInteractions.contains(selection)
      || questions.contains { $0.hostID == selection.host && $0.elicitation.sessionId == selection.session }
    let effective: PromptDelivery = delivery == .interrupt && protected ? .followUp : delivery
    return await prompt(from: selection, delivery: effective)
  }

  /// Starts the new chat in `place` with what is typed in it: how a chat starts somewhere other
  /// than the home folder.
  public func send(in place: NewChatPlace) async -> SendOutcome {
    guard !isSending, let selection, selection.session == nil, canSendDraft else { return .failed }
    isSending = true
    defer { isSending = false }
    return await startChat(in: place, from: selection)
  }

  private func text(of selection: Selection) -> String {
    draft(for: selection).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func startChat(in place: NewChatPlace, from draft: Selection) async -> SendOutcome {
    guard let workbench = await openNewChatHost(for: draft) else { return .failed }
    let revision = navigationRevision
    let target = DraftTarget(host: workbench.reference, place: place)
    let choice = draftModels[workbench.reference]
    let id: SessionID
    if let prepared = preparedChats[target] {
      id = prepared.sessionId
      if !workbench.sessions.contains(where: { $0.sessionId == id }) { workbench.update([prepared]) }
    } else {
      guard let created = await workbench.createChat(in: place) else { return .failed }
      preparedChats[target] = workbench.sessions.first { $0.sessionId == created }
      id = created
    }
    // Navigation, including A/B/A, retires this Send; keep any prepared chat for an explicit retry.
    guard navigationRevision == revision, selection == draft, current === workbench else { return .failed }
    preparedChats[target] = nil
    // The words move to the chat they started; a refusal leaves them in its box.
    let chat = Selection(host: draft.host, session: id)
    setDraft(self.draft(for: draft), for: chat)
    setDraft("", for: draft)
    draftFiles[chat] = draftFiles[draft]
    draftFiles[draft] = nil
    initialModels[chat] = choice
    select(host: draft.host, session: id)
    return await prompt(from: chat)
  }

  private func prompt(from selection: Selection, delivery: PromptDelivery = .interrupt) async -> SendOutcome {
    guard let workbench = current, workbench.reference.hostId == selection.host, let session = selection.session else { return .failed }
    let revision = navigationRevision
    if let choice = initialModels[selection] {
      guard await workbench.applyInitialModel(choice, in: session) else { return .failed }
      guard navigationRevision == revision, self.selection == selection, current === workbench else { return .failed }
      initialModels[selection] = nil
    }
    let text = text(of: selection)
    let files = attachments(for: selection)
    setDraft("", for: selection)
    draftFiles[selection] = nil
    let ready = files.compactMap { if case .ready(let a) = $0.state { a } else { nil } }
    switch await workbench.sendPrompt(text, attachments: ready, delivery: delivery) {
    case .accepted: return .sent
    case .uncertain: return .uncertain
    case .notSent:
      // Refused on its first try: the words and the files come back to the box.
      if draft(for: selection).isEmpty { setDraft(text, for: selection) }
      if attachments(for: selection).isEmpty, !files.isEmpty { draftFiles[selection] = files }
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
    navigationRevision += 1
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
  /// The Mac's home folder: where a chat goes unless it is told otherwise.
  case home
  /// The folder of another of the Mac's chats.
  case beside(SessionID)
}
