import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Everything the phone shows: the account's Macs, and the one open Session on one of them.
///
/// Only the selected Mac has a live connection; the others are listed from the relay's last
/// report. A Mac that is offline can still be read (its conversations are stored), it just
/// cannot be typed into.
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

  /// What is typed in each chat's box, kept while other chats are open. A new chat's is keyed by
  /// its Mac with no Session.
  private var drafts: [Selection: String] = [:]
  /// A message is on its way; a second tap must not start a second chat.
  public private(set) var isSending = false

  private let makeWorkbench: @MainActor (RemoteHost) -> HostWorkbenchModel
  private var started = false

  public init(hosts: HostsModel, makeWorkbench: @escaping @MainActor (RemoteHost) -> HostWorkbenchModel) {
    self.hosts = hosts
    self.makeWorkbench = makeWorkbench
  }

  /// Lists the Macs once and lands on a new chat, ready to be typed into, on the first Mac that is
  /// online (or the first there is). A chat only comes to exist when its first message is sent.
  public func start() async {
    guard !started else { return }
    started = true
    await hosts.refresh()
    guard selection == nil else { return }
    beginNewChat()
  }

  /// Whether the screen is on a new chat that does not exist yet.
  public var isDrafting: Bool { selection != nil && selection?.session == nil }

  /// Goes to a blank new chat on the open Mac (or the first online one). Nothing is created.
  public func beginNewChat() {
    guard let host = newChatHost ?? hosts.hosts.first else { return }
    select(host: host.hostId, session: nil)
  }

  public func refresh() async {
    await hosts.refresh()
    // The open Mac keeps its own live view; only a Mac that disappeared closes.
    if let selection, !hosts.hosts.contains(where: { $0.hostId == selection.host }), hosts.phase == .loaded {
      close()
    }
  }

  public func select(host hostID: UUID, session: SessionID?) {
    guard let remote = hosts.hosts.first(where: { $0.hostId == hostID }) else { return }
    if current?.reference.hostId != hostID {
      current?.stop()
      let workbench = makeWorkbench(remote)
      current = workbench
      Task { await workbench.start() }
    }
    selection = Selection(host: hostID, session: session)
    guard let workbench = current else { return }
    workbench.selectedSessionID = session
    if let session, workbench.historyStates[session] == nil { Task { await workbench.loadHistory(of: session) } }
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
    /// A new chat, and the Mac has several Workspaces: the person picks one, then `send(in:)`.
    case chooseWorkspace([RemoteWorkspace])
    /// Nothing was sent; the reason is in `current?.failure` and the words are back in the box.
    case failed
  }

  /// Sends what is typed in the open chat. On a new chat, the first message brings the chat into
  /// being: in the Mac's only Workspace at once, or in the one chosen; with none, it says so.
  /// The words leave the box as they go and come back if the Mac refuses them.
  public func send() async -> SendOutcome {
    guard !isSending, let selection, !text(of: selection).isEmpty else { return .failed }
    isSending = true
    defer { isSending = false }
    guard selection.session != nil else { return await startChat(from: selection) }
    return await prompt(from: selection)
  }

  /// Starts the new chat in `workspace` with what is typed in it.
  public func send(in workspace: UUID) async -> SendOutcome {
    guard !isSending, let selection, selection.session == nil, !text(of: selection).isEmpty else { return .failed }
    isSending = true
    defer { isSending = false }
    return await startChat(in: workspace, from: selection)
  }

  private func text(of selection: Selection) -> String {
    draft(for: selection).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func startChat(from draft: Selection) async -> SendOutcome {
    guard let workbench = await openNewChatHost(for: draft), let workspaces = await workbench.workspaces() else {
      return .failed
    }
    switch workspaces.count {
    case 0:
      workbench.report("This Mac has no workspaces yet. Create one in Axo on the Mac.")
      return .failed
    case 1:
      return await startChat(in: workspaces[0].workspaceId, from: draft)
    default:
      return .chooseWorkspace(workspaces)
    }
  }

  private func startChat(in workspace: UUID, from draft: Selection) async -> SendOutcome {
    guard let workbench = await openNewChatHost(for: draft) else { return .failed }
    await workbench.createChat(in: workspace)
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
    if await workbench.sendPrompt(text) { return .sent }
    if draft(for: selection).isEmpty { setDraft(text, for: selection) }
    return .failed
  }

  // MARK: - What the menu lists

  /// A Mac's Sessions as the menu should show them: live for the open Mac, as last listed for the
  /// others. The listing is only read on refresh, so the open Mac's chats made or renamed since
  /// would otherwise be missing.
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
}
