import CryptoKit
import Foundation

public enum DeviceLinkError: LocalizedError, Equatable {
  case invalidCode, expired, notConfirmed
  public var errorDescription: String? {
    switch self {
    case .invalidCode: "This is not an Axo linking code. Nothing was changed."
    case .expired: "This linking code expired. Open a new code on the other device."
    case .notConfirmed: "Linking was not confirmed. No keys were trusted. Check the other device before trying again."
    }
  }
}

/// A camera-only, expiring capability. Never put its contents in a URL, log or transcript.
public struct HostDeviceLinkCode: Codable, Sendable, Identifiable, CustomStringConvertible {
  public let version: Int
  public let id: String
  public let accountId: String
  public let hostId: String
  public let expiresAt: UInt64
  public let inputKey: String
  public let secret: String
  public var description: String { "<private Axo linking code>" }

  public var qrText: String {
    get throws { "AXO-LINK-1:" + (try JSONEncoder().encode(self)).base64EncodedString() }
  }

  public static func scan(_ text: String, account: UUID, now: Date = .now) throws -> Self {
    guard text.utf8.count <= 4096, text.hasPrefix("AXO-LINK-1:"),
      let data = Data(base64Encoded: String(text.dropFirst("AXO-LINK-1:".count))),
      let code = try? JSONDecoder().decode(Self.self, from: data), code.version == 1,
      UUID(uuidString: code.accountId) == account, UUID(uuidString: code.id) != nil, UUID(uuidString: code.hostId) != nil,
      let input = Data(base64Encoded: code.inputKey), (try? P256.KeyAgreement.PublicKey(x963Representation: input)) != nil,
      let secret = Data(base64Encoded: code.secret), secret.count == 32,
      (try? P256.Signing.PrivateKey(rawRepresentation: secret)) != nil else { throw DeviceLinkError.invalidCode }
    let time = UInt64(now.timeIntervalSince1970 * 1000)
    guard code.expiresAt > time, code.expiresAt <= time + 300_000 else { throw DeviceLinkError.expired }
    return code
  }

  public func claimMessage(key: String, name: String) -> Data {
    Data("axo-link-phone/v1\n\(id)\n\(accountId)\n\(hostId)\n\(expiresAt)\n\(inputKey)\n\(key)\n\(Data(name.utf8).base64EncodedString())\nhub".utf8)
  }

  public func claim(using signer: any DeviceSigner, name: String) throws -> DevicePairingClaim {
    guard let secret = Data(base64Encoded: secret) else { throw DeviceLinkError.invalidCode }
    let capability = try P256.Signing.PrivateKey(rawRepresentation: secret)
    let message = claimMessage(key: signer.publicKey, name: name)
    return DevicePairingClaim(id: id, accountId: accountId, hostId: hostId, key: signer.publicKey, name: name,
      signature: try signer.sign(message).base64EncodedString(), proof: try capability.signature(for: message).rawRepresentation.base64EncodedString())
  }

  public func verify(_ receipt: DevicePairingReceipt, claim: DevicePairingClaim, now: Date = .now) throws {
    guard receipt.paired, expiresAt > UInt64(now.timeIntervalSince1970 * 1000),
      claim.id == id, claim.accountId == accountId, claim.hostId == hostId,
      let secret = Data(base64Encoded: secret), let bytes = Data(base64Encoded: receipt.signature),
      let signature = try? P256.Signing.ECDSASignature(rawRepresentation: bytes),
      let capability = try? P256.Signing.PrivateKey(rawRepresentation: secret),
      capability.publicKey.isValidSignature(signature,
        for: Data("axo-link-phone-receipt/v1\n\(claimMessage(key: claim.key, name: claim.name).base64EncodedString())".utf8))
    else { throw DeviceLinkError.notConfirmed }
  }
}

public struct DevicePairingClaim: Codable, Sendable {
  public let id: String
  public let accountId: String
  public let hostId: String
  public let key: String
  public let name: String
  public let signature: String
  public let proof: String
}

public struct DevicePairingStatus: Codable, Sendable {
  public let id: String?
  public let paired: Bool
  public init(id: String?, paired: Bool) { self.id = id; self.paired = paired }
}

public struct DevicePairingReceipt: Codable, Sendable {
  public let paired: Bool
  public let signature: String
}

public struct DeviceLinkGrant: Codable, Sendable {
  public let accountId: String
  public let id: String
  public let hostId: String
  public let expiresAt: UInt64
  public let key: String
  public let name: String
  public let managerKey: String
  public var signature: String
  public let deviceSignature: String

  public func managerMessage() -> Data {
    Data("axo-link-grant/v1\n\(accountId)\n\(id)\n\(hostId)\n\(expiresAt)\n\(key)\n\(Data(name.utf8).base64EncodedString())\n\(managerKey)\nresponder".utf8)
  }

  public init(accountId: String, id: String, hostId: String, expiresAt: UInt64, key: String, name: String,
    managerKey: String, signature: String, deviceSignature: String) {
    self.accountId = accountId; self.id = id; self.hostId = hostId; self.expiresAt = expiresAt
    self.key = key; self.name = name; self.managerKey = managerKey
    self.signature = signature; self.deviceSignature = deviceSignature
  }
}
