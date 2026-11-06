import CryptoKit
import Foundation

/// Seals what the person typed for an input request to the Mac's input key (RFD0029, the side
/// channel for input), so the cloud carries only ciphertext. The same suite as axod's `axo-seal`
/// and the browser's: DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM.
public enum InputSeal {
  public static let info = Data("axo-ask-input/v1".utf8)

  public enum Failure: Error, Equatable {
    case badKey
  }

  /// What a sealed answer is bound to: its request, and the address the person was shown.
  public static func aad(requestID: String, origin: String?) -> Data {
    Data("\(requestID)\n\(origin ?? "")".utf8)
  }

  /// `values` by field id, sealed to `key` (base64 SEC1) for this request and address.
  public static func seal(_ values: [String: String], to key: String, requestID: String, origin: String?) throws -> SealedInput {
    guard let bytes = Data(base64Encoded: key), let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: bytes) else {
      throw Failure.badKey
    }
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: .P256_SHA256_AES_GCM_256, info: info)
    let plaintext = try JSONSerialization.data(withJSONObject: ["values": values], options: [.sortedKeys])
    let ciphertext = try sender.seal(plaintext, authenticating: aad(requestID: requestID, origin: origin))
    return SealedInput(enc: sender.encapsulatedKey.base64EncodedString(), ciphertext: ciphertext.base64EncodedString())
  }

  /// A short fingerprint of a key, to compare across devices: the first 8 bytes of its SHA-256 as
  /// four groups of hex, as the browser shows it.
  public static func fingerprint(of key: String) -> String {
    let digest = SHA256.hash(data: Data(base64Encoded: key) ?? Data())
    let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 4).map { offset in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return String(hex[start..<hex.index(start, offsetBy: 4)])
    }.joined(separator: " ")
  }
}

/// Each Mac's input key as first seen (trust on first use): values are sealed only to it, so a
/// key the cloud swapped in gets nothing.
public struct InputKeyPins: Sendable {
  public enum Check: Equatable, Sendable {
    case pinned, same, changed
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func check(host: UUID, key: String) -> Check {
    let name = "axo.inputKey.\(host.uuidString.lowercased())"
    guard let known = defaults.string(forKey: name) else {
      defaults.set(key, forKey: name)
      return .pinned
    }
    return known == key ? .same : .changed
  }
}

/// What a device sends with an answer (RFD0029, every remote answer is signed): its key, its name
/// and its signature over that answer alone.
public struct DeviceProof: Codable, Equatable, Sendable {
  public let key: String
  public let name: String
  public let signature: String

  public init(key: String, name: String, signature: String) {
    self.key = key
    self.name = name
    self.signature = signature
  }
}

/// A device's signing key: ECDSA P-256 over SHA-256, in the Secure Enclave where there is one.
public protocol DeviceSigner: Sendable {
  /// Base64 of the uncompressed public point, as the Mac knows the device.
  var publicKey: String { get }
  /// The raw 64-byte r‖s signature over `message`.
  func sign(_ message: Data) throws -> Data
}

extension DeviceSigner {
  /// What a device signs for one answer: the same bytes as axod's `axo_seal::answer_message`.
  public static func message(requestID: String, action: ElicitationAnswer, sealed: SealedInput?) -> Data {
    let digest = sealed.map { sealed in
      SHA256.hash(data: Data("\(sealed.enc)\n\(sealed.ciphertext)".utf8)).map { String(format: "%02x", $0) }.joined()
    } ?? ""
    return Data("axo-answer/v1\n\(requestID)\n\(action.rawValue)\n\(digest)".utf8)
  }

  public func prove(requestID: String, action: ElicitationAnswer, sealed: SealedInput?, name: String) throws -> DeviceProof {
    let signature = try sign(Self.message(requestID: requestID, action: action, sealed: sealed))
    return DeviceProof(key: publicKey, name: name, signature: signature.base64EncodedString())
  }
}

/// A software P-256 key: for tests, and where there is no Secure Enclave.
public struct SoftwareDeviceSigner: DeviceSigner {
  private let key: P256.Signing.PrivateKey

  public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
    self.key = key
  }

  public var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }

  public func sign(_ message: Data) throws -> Data {
    try key.signature(for: message).rawRepresentation
  }
}

/// A Secure Enclave P-256 key: its private half never leaves this device. `dataRepresentation`
/// is a blob only this device's Secure Enclave can use, kept to find the key again.
public struct SecureEnclaveDeviceSigner: DeviceSigner {
  private let key: SecureEnclave.P256.Signing.PrivateKey

  public init(dataRepresentation: Data?) throws {
    if let dataRepresentation {
      key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation)
    } else {
      key = try SecureEnclave.P256.Signing.PrivateKey()
    }
  }

  public var dataRepresentation: Data { key.dataRepresentation }
  public var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }

  public func sign(_ message: Data) throws -> Data {
    try key.signature(for: message).rawRepresentation
  }
}
