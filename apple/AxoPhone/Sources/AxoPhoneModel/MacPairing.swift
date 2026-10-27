import AxoClient
import AxoProtocol
import Foundation
import Observation

/// Linking one more Mac to the account from the phone: ask the relay for a code, show it until
/// the Mac redeems it (a Mac that was not listed before shows up) or it expires.
@MainActor
@Observable
public final class MacPairing {
  public enum State: Equatable {
    case creating
    /// Waiting for a Mac to redeem `pairing`.
    case waiting(HostPairing)
    /// The Mac called `label` redeemed the code.
    case linked(label: String)
    /// Nobody redeemed the code in time; a new one can be asked for.
    case expired
    case failed(String)
  }

  public private(set) var state: State = .creating

  /// How often the Macs are listed again while waiting.
  public static let pollInterval: Duration = .seconds(3)

  private let issuer: any HostPairingIssuing
  private let hosts: HostsModel
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    issuer: any HostPairingIssuing,
    hosts: HostsModel,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.issuer = issuer
    self.hosts = hosts
    self.now = now
    self.sleep = sleep
  }

  /// Asks for a code and waits for a Mac to redeem it. Run it in the task of the screen that
  /// shows the code: leaving the screen cancels the wait. Running it again starts over with a
  /// new code.
  public func run() async {
    state = .creating
    let known = Set(hosts.hosts.map(\.hostId))
    let pairing: HostPairing
    do {
      pairing = try await issuer.createHostPairing()
    } catch is CancellationError {
      return
    } catch {
      state = .failed(Self.describe(error))
      return
    }
    state = .waiting(pairing)
    while now() < pairing.expiresAt {
      do { try await sleep(Self.pollInterval) } catch { return }
      await hosts.refresh()
      if let linked = hosts.hosts.first(where: { !known.contains($0.hostId) }) {
        state = .linked(label: linked.label)
        return
      }
    }
    state = .expired
  }

  private static func describe(_ error: any Error) -> String {
    switch error as? RelayError {
    case .httpStatus(429): "Too many codes were asked for. Try again in a minute."
    case .signInRequired: "Sign in again to link a Mac."
    default: "Could not get a code: \(error.localizedDescription)"
    }
  }
}
