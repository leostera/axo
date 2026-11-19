import AxoClient
import AxoProtocol
import CryptoKit
import Foundation
import Observation

public protocol DeviceLinkingClient: Sendable {
  func redeemDevicePairing(_ claim: DevicePairingClaim) async throws -> DevicePairingReceipt
  func linkDevice(_ grant: DeviceLinkGrant) async throws
  func unlinkDevice(_ revocation: DeviceUnlink) async throws
  func deviceLinkMailbox(_ command: DeviceLinkMailboxCommand) async throws -> DeviceMailboxReceipt
}
extension AccountClient: DeviceLinkingClient {}

/// Public trust anchors, never private keys. Records belong to one account and signing identity.
public typealias LinkedHost = DeviceLinkHost

public struct LinkedClient: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let key: String
  public let name: String
  public let hostIds: [UUID]?
}

@MainActor
@Observable
public final class DeviceLinkingModel {
  public enum Phase: Equatable { case idle, linking, linked, waiting, confirming(String), failed(String) }
  public private(set) var phase: Phase = .idle
  public private(set) var linkedHosts: [LinkedHost] = []
  public private(set) var linkedClients: [LinkedClient] = []
  public private(set) var clientCode: ClientDeviceLinkCode?
  private var scannedClient: ClientDeviceLinkCode?
  private let client: any DeviceLinkingClient
  private let tokens: any SessionTokenProvider
  private let defaults: UserDefaults
  private let customSigner: (() throws -> any DeviceSigner)?
  private let name: String
  private var revision = UUID()

  private struct SavedLinks: Codable {
    let deviceKey: String
    let hosts: [LinkedHost]
    let clients: [LinkedClient]?
  }

  public init(client: any DeviceLinkingClient, tokens: any SessionTokenProvider, name: String,
    defaults: UserDefaults = .standard, signer: (() throws -> any DeviceSigner)? = nil) {
    self.client = client; self.tokens = tokens; self.defaults = defaults; self.customSigner = signer
    self.name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func storageKey(_ account: UUID) -> String { "axo.linkedHosts.v1." + account.uuidString.lowercased() }

  private func identity(for account: UUID) throws -> any DeviceSigner {
    if let customSigner { return try customSigner() }
    if defaults.data(forKey: storageKey(account)) != nil {
      return try PhoneDeviceKey.existing(in: defaults)
    }
    return try PhoneDeviceKey.stored(in: defaults)
  }

  public func load() async {
    revision = UUID()
    clientCode = nil
    scannedClient = nil
    phase = .idle
    linkedHosts = []
    linkedClients = []
    do {
      let session = try await tokens.sessionToken()
      let signer = try identity(for: session.accountID)
      if let data = defaults.data(forKey: storageKey(session.accountID)) {
        let saved = try JSONDecoder().decode(SavedLinks.self, from: data)
        guard saved.deviceKey == signer.publicKey else { throw DeviceLinkError.notConfirmed }
        for host in saved.hosts {
          guard let bytes = Data(base64Encoded: host.inputKey), (try? P256.KeyAgreement.PublicKey(x963Representation: bytes)) != nil
          else { throw DeviceLinkError.notConfirmed }
        }
        linkedHosts = saved.hosts
        linkedClients = saved.clients ?? []
      }
    } catch { phase = .failed("Your saved device links could not be restored. No identity or trusted key was replaced.") }
  }

  public func cancel() { revision = UUID(); scannedClient = nil; phase = .idle }

  public func showCode() async {
    guard phase != .linking else { return }
    let attempt = UUID()
    revision = attempt
    phase = .linking
    do {
      let session = try await tokens.sessionToken()
      let signer = try identity(for: session.accountID)
      let code = try ClientDeviceLinkCode.create(account: session.accountID, name: name.isEmpty ? "Device" : name, signer: signer)
      _ = try await client.deviceLinkMailbox(.create(code.candidate))
      guard revision == attempt else { return }
      guard (try await tokens.sessionToken()) == session else { phase = .idle; return }
      clientCode = code
      phase = .waiting
    } catch {
      guard revision == attempt else { return }
      phase = .failed("A linking code could not be created. Your existing identity was not replaced.")
    }
  }

  public func cancelWaiting() async {
    let code = clientCode
    clientCode = nil
    cancel()
    if let code { _ = try? await client.deviceLinkMailbox(.cancel(code.candidate.id)) }
  }

  /// Read-only reconciliation may retry; an uncertain approval is never automatically replayed.
  public func poll() async {
    guard phase == .waiting, let code = clientCode else { return }
    let attempt = revision
    do {
      let session = try await tokens.sessionToken()
      guard UUID(uuidString: code.candidate.accountId) == session.accountID else { throw DeviceLinkError.notConfirmed }
      guard code.candidate.expiresAt > UInt64(Date().timeIntervalSince1970 * 1000) else { throw DeviceLinkError.expired }
      let result = try await client.deviceLinkMailbox(.poll(code.candidate.id))
      guard revision == attempt, phase == .waiting else { return }
      guard (try await tokens.sessionToken()) == session else { phase = .idle; return }
      switch result.state {
      case .waiting: return
      case .cancelled: throw DeviceLinkError.notConfirmed
      case .complete:
        guard let box = result.box else { throw DeviceLinkError.notConfirmed }
        let bundle = try code.open(box)
        guard bundle.allowed else {
          clientCode = nil; phase = .failed("Pairing wasn’t allowed on the other phone."); return
        }
        let signer = try identity(for: session.accountID)
        guard signer.publicKey == code.candidate.key else { throw DeviceLinkError.notConfirmed }
        let saved = SavedLinks(deviceKey: signer.publicKey, hosts: bundle.hosts, clients: [])
        defaults.set(try JSONEncoder().encode(saved), forKey: storageKey(session.accountID))
        for host in bundle.hosts { InputKeyPins(defaults: defaults).confirm(host.inputKey) }
        linkedHosts = bundle.hosts
        clientCode = nil
        phase = .linked
      }
    } catch let error as DeviceLinkError {
      guard revision == attempt else { return }
      clientCode = nil
      phase = .failed(error.localizedDescription)
    } catch {
      // A temporary read failure is not consent, sign-out, or a reason to regenerate the QR.
      if code.candidate.expiresAt <= UInt64(Date().timeIntervalSince1970 * 1000) {
        clientCode = nil; phase = .failed(DeviceLinkError.expired.localizedDescription)
      }
    }
  }

  public func scan(_ text: String) async {
    guard phase != .linking else { return }
    if text.hasPrefix("AXO-LINK-1:") { await scanHost(text); return }
    do {
      let session = try await tokens.sessionToken()
      let code = try ClientDeviceLinkCode.scan(text, account: session.accountID)
      let signer = try identity(for: session.accountID)
      guard code.candidate.key != signer.publicKey else { throw DeviceLinkError.invalidCode }
      guard linkedHosts.contains(where: \.canLinkDevices) else {
        phase = .failed("Link this phone to an existing Axo first. Signing in alone cannot approve another device."); return
      }
      revision = UUID()
      scannedClient = code
      phase = .confirming(code.candidate.name)
    } catch { phase = .failed(DeviceLinkError.invalidCode.localizedDescription) }
  }

  public func decideScannedClient(allow: Bool) async {
    guard let code = scannedClient, case .confirming = phase else { return }
    let attempt = UUID()
    revision = attempt
    phase = .linking
    do {
      let session = try await tokens.sessionToken()
      guard UUID(uuidString: code.candidate.accountId) == session.accountID,
        code.candidate.expiresAt > UInt64(Date().timeIntervalSince1970 * 1000) else { throw DeviceLinkError.expired }
      let signer = try identity(for: session.accountID)
      let targets = linkedHosts.filter(\.canLinkDevices)
      guard !targets.isEmpty, targets.count <= 24 else { throw DeviceLinkError.notConfirmed }
      if allow {
        for target in targets {
          guard revision == attempt, (try await tokens.sessionToken()) == session else { throw DeviceLinkError.notConfirmed }
          try await client.linkDevice(code.grant(to: target.hostId, using: signer))
        }
      }
      guard revision == attempt, (try await tokens.sessionToken()) == session else { throw DeviceLinkError.notConfirmed }
      let hosts = allow ? targets.map { LinkedHost(hostId: $0.hostId, inputKey: $0.inputKey, canLinkDevices: false) } : []
      let bundle = DeviceLinkBundle(candidate: code.candidate, allowed: allow, hosts: hosts)
      _ = try await client.deviceLinkMailbox(.complete(id: code.candidate.id, box: code.seal(bundle)))
      guard revision == attempt, (try await tokens.sessionToken()) == session else { return }
      if allow {
        let linked = LinkedClient(id: code.candidate.id, key: code.candidate.key, name: code.candidate.name, hostIds: targets.map(\.hostId))
        var clients = linkedClients.filter { $0.key != linked.key }
        clients.append(linked)
        defaults.set(try JSONEncoder().encode(SavedLinks(deviceKey: signer.publicKey, hosts: linkedHosts, clients: clients)), forKey: storageKey(session.accountID))
        linkedClients = clients
      }
      scannedClient = nil
      phase = allow ? .linked : .idle
    } catch {
      guard revision == attempt else { return }
      phase = .failed("Linking was not confirmed. Some Axos may already have accepted this device. Check before retrying; nothing was automatically replayed.")
    }
  }

  public func unlink(_ linked: LinkedClient) async {
    guard phase != .linking, linkedClients.contains(where: { $0.id == linked.id && $0.key == linked.key }) else { return }
    let attempt = UUID()
    revision = attempt
    phase = .linking
    do {
      let session = try await tokens.sessionToken()
      let signer = try identity(for: session.accountID)
      let targets = linkedHosts.filter { $0.canLinkDevices && (linked.hostIds?.contains($0.hostId) ?? true) }
      guard !targets.isEmpty else { throw DeviceLinkError.notConfirmed }
      for target in targets {
        guard revision == attempt, (try await tokens.sessionToken()) == session else { throw DeviceLinkError.notConfirmed }
        try await client.unlinkDevice(DeviceUnlink(account: session.accountID, host: target.hostId, linkID: linked.id, key: linked.key, manager: signer))
      }
      guard revision == attempt, (try await tokens.sessionToken()) == session else { return }
      let clients = linkedClients.filter { $0.key != linked.key }
      defaults.set(try JSONEncoder().encode(SavedLinks(deviceKey: signer.publicKey, hosts: linkedHosts, clients: clients)), forKey: storageKey(session.accountID))
      linkedClients = clients
      phase = .idle
    } catch {
      guard revision == attempt else { return }
      phase = .failed("Unlinking was not confirmed on every linked computer. Check before retrying.")
    }
  }

  public func scanHost(_ text: String) async {
    guard phase != .linking else { return }
    let attempt = UUID()
    revision = attempt
    phase = .linking
    do {
      let session = try await tokens.sessionToken()
      let code = try HostDeviceLinkCode.scan(text, account: session.accountID)
      let signer = try identity(for: session.accountID)
      let claim = try code.claim(using: signer, name: name.isEmpty ? "Phone" : name)
      let receipt = try await client.redeemDevicePairing(claim)
      guard revision == attempt else { return }
      guard (try await tokens.sessionToken()) == session else { phase = .idle; return }
      try code.verify(receipt, claim: claim)
      guard let host = UUID(uuidString: code.hostId) else { throw DeviceLinkError.invalidCode }
      var next = linkedHosts.filter { $0.hostId != host }
      next.append(LinkedHost(hostId: host, inputKey: code.inputKey, canLinkDevices: true))
      let data = try JSONEncoder().encode(SavedLinks(deviceKey: signer.publicKey, hosts: next, clients: linkedClients))
      defaults.set(data, forKey: storageKey(session.accountID))
      // The camera authenticated this exact host key and the receipt authenticated the grant.
      // Never confirm a cloud-delivered key merely because a request names a known host.
      InputKeyPins(defaults: defaults).confirm(code.inputKey)
      linkedHosts = next
      phase = .linked
    } catch {
      guard revision == attempt else { return }
      // Transport exceptions may contain URLs or diagnostics. Never print the scanned capability.
      phase = .failed((error as? DeviceLinkError)?.localizedDescription
        ?? "Linking was not confirmed. Check the other device before trying again.")
    }
  }
}
