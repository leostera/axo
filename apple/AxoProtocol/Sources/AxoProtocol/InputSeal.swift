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
