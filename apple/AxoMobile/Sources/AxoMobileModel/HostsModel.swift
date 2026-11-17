import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Who is signed in, for the account screen.
public protocol SignedInAccountLoading: Sendable {
  /// Nil when it cannot be read.
  func signedInAccount() async -> SignedInAccount?
}

extension AccountClient: SignedInAccountLoading {
  public func signedInAccount() async -> SignedInAccount? { try? await account() }
}

/// The account's hosts and their Sessions, as the account's socket last listed them (RFD0018):
/// the whole listing on every hello, then each change as it happens.
@MainActor
@Observable
public final class HostsModel {
  public enum Phase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  public private(set) var hosts: [RemoteHost] = []
  public private(set) var phase: Phase = .idle
  /// Who is signed in, once read.
  public private(set) var signedIn: SignedInAccount?

  private let profile: any SignedInAccountLoading
  private var listed: [ClientHost] = []
  private var sessions: [UUID: [SessionID: RemoteSession]] = [:]

  public init(profile: any SignedInAccountLoading) {
    self.profile = profile
  }

  /// Waiting for the first listing.
  func loading() {
    if phase != .loaded { phase = .loading }
    if signedIn == nil { Task { signedIn = await profile.signedInAccount() } }
  }

  /// The first listing could not be read.
  func failed(_ message: String) {
    if phase != .loaded { phase = .failed(message) }
  }

  /// A whole listing: every host and Session, replacing what was known.
  func adopt(_ listing: ClientHello) {
    listed = listing.hosts
    sessions = [:]
    for session in listing.sessions where !session.metadata.archived {
      sessions[session.hostId, default: [:]][session.sessionId] = RemoteSession(session)
    }
    rebuild()
    phase = .loaded
  }

  /// The host list changed (a presence moved, a host was paired or revoked).
  func update(hosts: [ClientHost]) {
    listed = hosts
    for host in sessions.keys where !hosts.contains(where: { $0.hostId == host }) { sessions[host] = nil }
    rebuild()
  }

  /// A host was named: shown by its new name at once, before the account's notice arrives.
  func renamed(_ hostID: UUID, to label: String) {
    listed = listed.map { host in
      host.hostId == hostID ? host.named(label) : host
    }
    rebuild()
  }

  /// Some of one host's Sessions changed.
  func update(sessions changed: [ClientSession], of host: UUID) {
    // An archived chat leaves the list; the cloud keeps it.
    for session in changed where session.hostId == host {
      sessions[host, default: [:]][session.sessionId] = session.metadata.archived ? nil : RemoteSession(session)
    }
    rebuild()
  }

  private func rebuild() {
    let built = listed.map { host in
      RemoteHost(host, sessions: (sessions[host.hostId]?.values).map { Array($0) } ?? [])
    }
    hosts = built.sorted { ($0.status == .online ? 0 : 1, $0.label) < ($1.status == .online ? 0 : 1, $1.label) }
  }
}
