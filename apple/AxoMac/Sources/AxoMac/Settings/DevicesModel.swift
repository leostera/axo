import AxoClient
import AxoProtocol
import Foundation
import Observation

/// The daemon operations for the devices that answer this Mac's questions (RFD0077). axod takes
/// `decideDevice` and `revokeDevice` only from Axo.app, by code signature.
@MainActor
protocol AxodDevicesClient: AnyObject {
  func remoteAccessStatus() async throws -> RemoteAccessStatus
  func linkHost(using code: HostPairingCode) async throws -> HostPairingResult
  func createDeviceLinkCode() async throws -> HostDeviceLinkCode
  func devicePairingStatus() async throws -> DevicePairingStatus
  func cancelDeviceLinkCode() async throws
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
  private(set) var linkCode: HostDeviceLinkCode?
  private(set) var creatingLinkCode = false
  private(set) var needsSignIn = false
  private(set) var linkCompleted = false
  @ObservationIgnored private var linkRevision = UUID()
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
      let status = try await client.remoteAccessStatus()
      needsSignIn = status.linked == false
      if let linkCode {
        let progress = try await client.devicePairingStatus()
        if progress.id == linkCode.id, progress.paired { self.linkCode = nil; linkCompleted = true }
      }
      failure = nil
    } catch {
      failure = "Axo couldn’t read the devices: \(error.localizedDescription)"
    }
  }

  /// A native sign-in enrolls the host without making the person copy an eight-character code.
  /// The temporary native session is never persisted on this Mac; the host keeps its own credential.
  func linkToAccount(using token: SessionToken) async throws {
    guard let client else { throw SessionCommandError("axod is not running.") }
    guard try await client.remoteAccessStatus().linked == false else { return }
    let account = AccountClient(tokens: StaticSessionToken(token))
    do {
      let pairing = try await account.createHostPairing()
      guard try await client.remoteAccessStatus().linked == false else {
        try? await account.signOut(); return
      }
      _ = try await client.linkHost(using: pairing.code)
      try? await account.signOut()
      await refresh()
    } catch {
      try? await account.signOut()
      throw error
    }
  }

  func createLinkCode() async {
    guard let client, !creatingLinkCode else { return }
    let revision = UUID()
    linkRevision = revision
    creatingLinkCode = true
    linkCompleted = false
    defer { creatingLinkCode = false }
    do {
      let code = try await client.createDeviceLinkCode()
      guard linkRevision == revision else { try? await client.cancelDeviceLinkCode(); return }
      linkCode = code
      failure = nil
    } catch { failure = "Axo couldn’t create a linking code. Connect Remote Access and try again." }
  }

  func cancelLinkCode() async {
    linkRevision = UUID()
    linkCode = nil
    try? await client?.cancelDeviceLinkCode()
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
