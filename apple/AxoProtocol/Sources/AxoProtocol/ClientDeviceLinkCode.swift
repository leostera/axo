import CryptoKit
import Foundation

public struct DeviceLinkHost: Codable, Equatable, Identifiable, Sendable {
  public let hostId: UUID
  public let inputKey: String
  public let canLinkDevices: Bool
  public var id: UUID { hostId }
  public init(hostId: UUID, inputKey: String, canLinkDevices: Bool) {
    self.hostId = hostId; self.inputKey = inputKey; self.canLinkDevices = canLinkDevices
  }
}

public struct DeviceLinkCandidate: Codable, Sendable {
  public let accountId: String
  public let id: String
  public let expiresAt: UInt64
  public let key: String
  public let name: String
  public var signature: String

  public func message() -> Data {
    Data("axo-link-recipient/v1\n\(accountId)\n\(id)\n\(expiresAt)\n\(key)\n\(Data(name.utf8).base64EncodedString())".utf8)
  }
}

public struct DeviceLinkBundle: Codable, Sendable {
  public let accountId: String
  public let id: String
  public let key: String
  public let allowed: Bool
  public let hosts: [DeviceLinkHost]

  public init(candidate: DeviceLinkCandidate, allowed: Bool, hosts: [DeviceLinkHost]) {
    accountId = candidate.accountId; id = candidate.id; key = candidate.key
    self.allowed = allowed; self.hosts = hosts
  }
}

/// The public request goes to the mailbox; the symmetric capability is shown only as a QR.
public struct ClientDeviceLinkCode: Codable, Sendable, Identifiable, CustomStringConvertible {
  public var id: String { candidate.id }
  public let version: Int
  public let candidate: DeviceLinkCandidate
  private let secret: String
  public var description: String { "<private Axo client linking code>" }
  public var qrText: String { get throws { "AXO-CLIENT-LINK-1:" + (try JSONEncoder().encode(self)).base64EncodedString() } }

  public static func create(account: UUID, name: String, signer: any DeviceSigner, now: Date = .now) throws -> Self {
    let expiry = UInt64(now.timeIntervalSince1970 * 1000) + 300_000
    var candidate = DeviceLinkCandidate(accountId: account.uuidString.lowercased(), id: UUID().uuidString.lowercased(),
      expiresAt: expiry, key: signer.publicKey, name: name, signature: "")
    candidate.signature = try signer.sign(candidate.message()).base64EncodedString()
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    return Self(version: 1, candidate: candidate, secret: secret)
  }

  public static func scan(_ text: String, account: UUID, now: Date = .now) throws -> Self {
    guard text.utf8.count <= 4096, text.hasPrefix("AXO-CLIENT-LINK-1:"),
      let bytes = Data(base64Encoded: String(text.dropFirst("AXO-CLIENT-LINK-1:".count))),
      let code = try? JSONDecoder().decode(Self.self, from: bytes), code.version == 1,
      UUID(uuidString: code.candidate.accountId) == account, UUID(uuidString: code.candidate.id) != nil,
      let secret = Data(base64Encoded: code.secret), secret.count == 32,
      !code.candidate.name.isEmpty, code.candidate.name.count <= 80,
      code.candidate.name.trimmingCharacters(in: .whitespacesAndNewlines) == code.candidate.name,
      !code.candidate.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let key = Data(base64Encoded: code.candidate.key), let signature = Data(base64Encoded: code.candidate.signature),
      let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
      let signed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
      publicKey.isValidSignature(signed, for: code.candidate.message()) else { throw DeviceLinkError.invalidCode }
    let time = UInt64(now.timeIntervalSince1970 * 1000)
    guard code.candidate.expiresAt > time, code.candidate.expiresAt <= time + 300_000 else { throw DeviceLinkError.expired }
    return code
  }

  public func grant(to host: UUID, using manager: any DeviceSigner) throws -> DeviceLinkGrant {
    var grant = DeviceLinkGrant(accountId: candidate.accountId, id: candidate.id,
      hostId: host.uuidString.lowercased(), expiresAt: candidate.expiresAt, key: candidate.key, name: candidate.name,
      managerKey: manager.publicKey, signature: "", deviceSignature: candidate.signature)
    grant.signature = try manager.sign(grant.managerMessage()).base64EncodedString()
    return grant
  }

  private var aad: Data { Data("axo-client-link/v1\n\(candidate.accountId)\n\(candidate.id)\n\(candidate.key)\n\(candidate.expiresAt)".utf8) }

  public func seal(_ bundle: DeviceLinkBundle) throws -> String {
    guard let secret = Data(base64Encoded: secret) else { throw DeviceLinkError.invalidCode }
    let sealed = try AES.GCM.seal(JSONEncoder().encode(bundle), using: SymmetricKey(data: secret), authenticating: aad)
    guard let combined = sealed.combined else { throw DeviceLinkError.notConfirmed }
    return combined.base64EncodedString()
  }

  public func open(_ box: String, now: Date = .now) throws -> DeviceLinkBundle {
    guard candidate.expiresAt > UInt64(now.timeIntervalSince1970 * 1000), box.utf8.count <= 6000,
      let secret = Data(base64Encoded: secret), let bytes = Data(base64Encoded: box),
      let sealed = try? AES.GCM.SealedBox(combined: bytes),
      let plaintext = try? AES.GCM.open(sealed, using: SymmetricKey(data: secret), authenticating: aad),
      let bundle = try? JSONDecoder().decode(DeviceLinkBundle.self, from: plaintext),
      bundle.accountId == candidate.accountId, bundle.id == candidate.id, bundle.key == candidate.key,
      bundle.hosts.count <= 24, Set(bundle.hosts.map(\.hostId)).count == bundle.hosts.count,
      bundle.hosts.allSatisfy({ host in
        guard !host.canLinkDevices, let key = Data(base64Encoded: host.inputKey) else { return false }
        return (try? P256.KeyAgreement.PublicKey(x963Representation: key)) != nil
      }) else { throw DeviceLinkError.notConfirmed }
    return bundle
  }
}

public enum DeviceLinkMailboxCommand: Encodable, Sendable {
  case create(DeviceLinkCandidate), poll(String), complete(id: String, box: String), cancel(String)
  private enum Keys: String, CodingKey { case operation, candidate, id, box }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    switch self {
    case .create(let candidate):
      try container.encode("create", forKey: .operation)
      try container.encode(candidate, forKey: .candidate)
    case .poll(let id):
      try container.encode("poll", forKey: .operation); try container.encode(id, forKey: .id)
    case .cancel(let id):
      try container.encode("cancel", forKey: .operation); try container.encode(id, forKey: .id)
    case .complete(let id, let box):
      try container.encode("complete", forKey: .operation); try container.encode(id, forKey: .id)
      try container.encode(box, forKey: .box)
    }
  }
}

public struct DeviceMailboxReceipt: Codable, Sendable {
  public enum State: String, Codable, Sendable { case waiting, complete, cancelled }
  public let state: State
  public let box: String?
}
