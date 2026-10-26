import AxoClient
import AxoProtocol
import Foundation
import Observation

public protocol HostListing: Sendable {
  func hosts() async throws -> [RemoteHost]
}

extension AccountClient: HostListing {}

/// The account's hosts, as the relay last reported them.
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

  private let listing: any HostListing
  private let account: AccountSession

  public init(listing: any HostListing, account: AccountSession) {
    self.listing = listing
    self.account = account
  }

  public func refresh() async {
    phase = .loading
    do {
      let found = try await listing.hosts()
      hosts = found.sorted { ($0.status == .online ? 0 : 1, $0.label) < ($1.status == .online ? 0 : 1, $1.label) }
      phase = .loaded
    } catch is CancellationError {
      phase = hosts.isEmpty ? .idle : .loaded
    } catch {
      if account.noteFailure(error) { hosts = [] }
      phase = .failed(error.localizedDescription)
    }
  }
}
