import AxoProtocol
import CryptoKit
import Foundation

/// This installation's answer-signing identity. Restoring an existing key must never create a
/// replacement: a locked/unavailable Secure Enclave is an error, not a reason to change identity.
public enum PhoneDeviceKey {
  private static let enclaveName = "axo.deviceKey.enclave"
  private static let softwareName = "axo.deviceKey.software"

  /// Injectable hardware effects keep tests independent of the machine's actual Secure Enclave.
  public struct Enclave {
    public struct CreatedKey {
      public let signer: any DeviceSigner
      public let representation: Data

      public init(signer: any DeviceSigner, representation: Data) {
        self.signer = signer
        self.representation = representation
      }
    }

    public let restore: (Data) throws -> any DeviceSigner
    public let create: () throws -> CreatedKey

    public init(restore: @escaping (Data) throws -> any DeviceSigner, create: @escaping () throws -> CreatedKey) {
      self.restore = restore
      self.create = create
    }

    public static var current: Enclave? {
      guard SecureEnclave.isAvailable else { return nil }
      return Enclave(
        restore: { try SecureEnclaveDeviceSigner(dataRepresentation: $0) },
        create: {
          let signer = try SecureEnclaveDeviceSigner(dataRepresentation: nil)
          return CreatedKey(signer: signer, representation: signer.dataRepresentation)
        }
      )
    }
  }

  public enum StorageError: LocalizedError, Equatable {
    case unavailable, cannotRestore, cannotCreate, missingMigrationKey, identityMismatch

    public var errorDescription: String? {
      switch self {
      case .unavailable, .cannotRestore:
        return "Approval key storage is unavailable. Unlock this device and try again. Axo has not replaced any key."
      case .cannotCreate:
        return "This device could not create its approval key. Nothing was sent."
      case .missingMigrationKey:
        return "There is no saved Secure Enclave identity to migrate. Nothing has been changed."
      case .identityMismatch:
        return "The restored approval key does not match the existing identity. Nothing has been changed."
      }
    }
  }

  public static func stored(in defaults: UserDefaults = .standard, enclave: Enclave? = .current) throws -> any DeviceSigner {
    if let saved = defaults.object(forKey: enclaveName) {
      guard let representation = saved as? Data, !representation.isEmpty else { throw StorageError.cannotRestore }
      guard let enclave else { throw StorageError.unavailable }
      do { return try enclave.restore(representation) }
      catch { throw StorageError.cannotRestore }
    }
    // Preserve an existing software identity too; upgrading hardware availability is not consent
    // to replace an already enrolled key. New physical-device identities never fall back to it.
    if let saved = defaults.object(forKey: softwareName) {
      guard let raw = saved as? Data, let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
      else { throw StorageError.cannotRestore }
      return SoftwareDeviceSigner(key: key)
    }
    if let enclave {
      do {
        let created = try enclave.create()
        guard !created.representation.isEmpty else { throw StorageError.cannotCreate }
        defaults.set(created.representation, forKey: enclaveName)
        return created.signer
      } catch { throw StorageError.cannotCreate }
    }
    #if targetEnvironment(simulator)
      let key = P256.Signing.PrivateKey()
      defaults.set(key.rawRepresentation, forKey: softwareName)
      return SoftwareDeviceSigner(key: key)
    #else
      throw StorageError.unavailable
    #endif
  }

  /// The importer may restore only a supplied opaque Enclave reference, never generate a key.
  /// Public-key equality and a fresh signing proof are both required before any destination write.
  /// This proves restoration, not cross-app accessibility: that still needs physical-device tests.
  public static func restoreForMigration(
    _ representation: Data, expectedPublicKey: String, enclave: Enclave? = .current
  ) throws -> any DeviceSigner {
    guard !representation.isEmpty, representation.count <= 16_384 else { throw StorageError.missingMigrationKey }
    guard let enclave else { throw StorageError.unavailable }
    let signer: any DeviceSigner
    do { signer = try enclave.restore(representation) }
    catch { throw StorageError.cannotRestore }
    guard signer.publicKey == expectedPublicKey,
      let bytes = Data(base64Encoded: expectedPublicKey),
      let publicKey = try? P256.Signing.PublicKey(x963Representation: bytes)
    else { throw StorageError.identityMismatch }
    let challenge = Data("axo-identity-migration/v1\n".utf8) + Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    do {
      let signature = try P256.Signing.ECDSASignature(rawRepresentation: signer.sign(challenge))
      guard publicKey.isValidSignature(signature, for: challenge) else { throw StorageError.identityMismatch }
    } catch { throw StorageError.identityMismatch }
    return signer
  }
}
