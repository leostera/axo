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

  /// Lists the Macs once, and opens the first online one with a Session if nothing is open yet.
  public func start() async {
    guard !started else { return }
    started = true
    await hosts.refresh()
    guard selection == nil else { return }
    let candidates = hosts.hosts.filter { !$0.sessions.isEmpty }
    if let first = candidates.first {
      select(host: first.hostId, session: first.sessions.sorted { $0.sessionId < $1.sessionId }.first?.sessionId)
    }
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
    if let session, let workbench = current {
      workbench.selectedSessionID = session
      if workbench.historyStates[session] == nil { Task { await workbench.loadHistory(of: session) } }
    }
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
    /// The chat is open.
    case started
    /// The Mac has several Workspaces; the person picks one, then `startChat(in:)`.
    case chooseWorkspace([RemoteWorkspace])
    /// Nothing started; the reason is in `current?.failure`.
    case failed
  }

  /// Asks for a new chat on `newChatHost`: opens it at once when the Mac has one Workspace, and
  /// asks which when it has several.
  public func startChat() async -> ChatStart {
    guard let workbench = await openNewChatHost(), let workspaces = await workbench.workspaces() else {
      return .failed
    }
    switch workspaces.count {
    case 0:
      workbench.report("This Mac has no workspaces yet. Create one in Axo on the Mac.")
      return .failed
    case 1:
      return await startChat(in: workspaces[0].workspaceId)
    default:
      return .chooseWorkspace(workspaces)
    }
  }

  /// Starts a chat in a Workspace of `newChatHost` and opens it.
  public func startChat(in workspace: UUID) async -> ChatStart {
    guard let workbench = await openNewChatHost() else { return .failed }
    await workbench.createChat(in: workspace)
    guard workbench.failure == nil, let id = workbench.selectedSessionID else { return .failed }
    select(session: id)
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
