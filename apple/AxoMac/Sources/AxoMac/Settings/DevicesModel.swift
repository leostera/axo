import AxoClient
import AxoProtocol
import Foundation
import Observation

/// The daemon operations for the devices that answer this Mac's questions (RFD0069). axod takes
/// `decideDevice` and `revokeDevice` only from Axo.app, by code signature.
@MainActor
protocol AxodDevicesClient: AnyObject {
  func answeringDevices() async throws -> AnsweringDevices
  func decideDevice(_ key: String, allow: Bool) async throws
  func revokeDevice(_ key: String) async throws
}

extension AxodConnection: AxodDevicesClient {}

/// Settings › Devices: which phones and browsers may answer for this Mac. A device the Mac does
/// not know is refused and waits here; the person allows it only when the fingerprint shown is the
/// one the device shows. This Mac's input key's fingerprint is here too, for a device to compare
/// before it first sends typed values.
@MainActor
@Observable
final class DevicesModel {
  private(set) var devices: AnsweringDevices?
  /// Devices whose decision or removal is on its way to axod.
  private(set) var busy: Set<String> = []
  /// Why the list could not be read, or a choice not saved, worded for the person.
  private(set) var failure: String?
  @ObservationIgnored private let client: AxodDevicesClient?

  init(client: AxodDevicesClient?) {
    self.client = client
  }

  func refresh() async {
    guard let client else {
      failure = "axod is not running."
      return
    }
    do {
      devices = try await client.answeringDevices()
      failure = nil
    } catch {
      failure = "Axo couldn’t read the devices: \(error.localizedDescription)"
    }
  }

  /// Allows a waiting device to answer this Mac's questions, or turns it away.
  func decide(_ key: String, allow: Bool) async {
    guard let client, devices?.waiting.contains(where: { $0.key == key }) == true else { return }
    await change(key) { try await client.decideDevice(key, allow: allow) }
  }

  /// Stops taking an allowed device's answers.
  func revoke(_ key: String) async {
    guard let client, devices?.allowed.contains(where: { $0.key == key }) == true else { return }
    await change(key) { try await client.revokeDevice(key) }
  }

  private func change(_ key: String, _ action: () async throws -> Void) async {
    guard !busy.contains(key) else { return }
    busy.insert(key)
    defer { busy.remove(key) }
    do {
      try await action()
      await refresh()
    } catch {
      failure = "Axo couldn’t save that: \(error.localizedDescription)"
    }
  }
}
