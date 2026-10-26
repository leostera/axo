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
  public struct Selection: Equatable, Sendable {
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

  /// How asking for a new chat went.
  public enum ChatStart: Equatable, Sendable {
    /// The chat exists and is open.
    case started
    /// The Mac has several Workspaces; the person picks one, then `startChat(in:sending:)`.
    case chooseWorkspace([RemoteWorkspace])
    /// Nothing started; the reason is in `current?.failure`.
    case failed
  }

  /// Brings a new chat into being on `newChatHost` for its first message, `first`, and opens it.
  /// With one Workspace on the Mac it starts there at once; with several it asks which; with none
  /// it says so. If the chat starts but the Mac then refuses the message, the chat stays open and
  /// the reason is in `current?.failure`, so the caller keeps the words.
  public func startChat(sending first: String) async -> ChatStart {
    guard let workbench = await openNewChatHost(), let workspaces = await workbench.workspaces() else {
      return .failed
    }
    switch workspaces.count {
    case 0:
      workbench.report("This Mac has no workspaces yet. Create one in Axo on the Mac.")
      return .failed
    case 1:
      return await startChat(in: workspaces[0].workspaceId, sending: first)
    default:
      return .chooseWorkspace(workspaces)
    }
  }

  /// Starts the chat in a Workspace of `newChatHost`, opens it and sends `first`.
  public func startChat(in workspace: UUID, sending first: String) async -> ChatStart {
    guard let workbench = await openNewChatHost() else { return .failed }
    await workbench.createChat(in: workspace)
    guard workbench.failure == nil, let id = workbench.selectedSessionID else { return .failed }
    select(session: id)
    _ = await workbench.sendPrompt(first)
    return .started
  }

  private func openNewChatHost() async -> HostWorkbenchModel? {
    guard let host = newChatHost else { return nil }
    if current?.reference.hostId != host.hostId { select(host: host.hostId, session: nil) }
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
