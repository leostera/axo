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
