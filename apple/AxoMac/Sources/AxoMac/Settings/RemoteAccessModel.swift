import AxoRPC
import Foundation
import Observation

/// Remote-access state for Settings. Axod pushes changes as `relay.status` catalog events, so
/// nothing polls; `refresh()` runs only when the catalog (re)connects or after a user action.
@MainActor
@Observable
final class RemoteAccessModel {
  private(set) var status: RemoteAccessStatus?
  /// Why `status` is unavailable, worded for the user.
  private(set) var statusError: String?
  @ObservationIgnored private let client: AxodSettingsClient?

  init(client: AxodSettingsClient?) {
    self.client = client
    statusError = client == nil ? "axod is not running." : nil
  }

  func apply(_ status: RemoteAccessStatus) {
    if self.status != status { self.status = status }
    if statusError != nil { statusError = nil }
  }

  /// Axod is unreachable; forget the last known state rather than show it as current.
  func reset() {
    if status != nil { status = nil }
    if statusError != "axod is not running." { statusError = "axod is not running." }
  }

  func refresh() async {
    do {
      apply(try await requireClient().remoteAccessStatus())
    } catch {
      if status != nil { status = nil }
      statusError = error.localizedDescription
    }
  }

  func connect() async throws {
    try await requireClient().requestRemoteAccessConnection()
    await refresh()
  }

  func link(using code: HostPairingCode) async throws -> HostPairingResult {
    let result = try await requireClient().linkHost(using: code)
    await refresh()
    return result
  }

  private func requireClient() throws -> AxodSettingsClient {
    guard let client else { throw SessionCommandError("axod is not running.") }
    return client
  }
}
