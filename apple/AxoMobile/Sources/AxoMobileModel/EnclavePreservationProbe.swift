import AxoProtocol
import CryptoKit
import Foundation

/// A narrow cross-app preservation test. It transfers no login/preferences, creates no key,
/// writes no destination identity, and never enables the destination's ordinary workbench.
public enum EnclavePreservationProbe {
  public enum Role: String, Codable, Sendable {
    case mobile, watch
    public var sourceBundleID: String {
      self == .mobile ? "dev.leostera.axo.phone" : "dev.leostera.axo.phone.watchkitapp"
    }
    public var destinationBundleID: String {
      self == .mobile ? "dev.leostera.axo" : "dev.leostera.axo.watch"
    }
  }

  public enum Failure: Error, Equatable {
    case malformed, wrongIdentity, expired, unsupportedSoftwareKey, unavailable, conflictingDestination
  }

  public enum Outcome: String, Codable, Sendable {
    case prepared, verified, noExistingKey
  }

  /// Only the app's explicitly entitled device-local Keychain adapter may carry these bytes.
  public protocol Storing {
    func load(for role: Role) throws -> Data?
    func save(_ data: Data, for role: Role) throws
  }

  private struct Envelope: Codable {
    let version: Int
    let transferID: UUID
    let role: Role
    let sourceBundleID: String
    let destinationBundleID: String
    let createdAt: TimeInterval
    let reference: Data?
    let publicKey: String?
  }

  private static let enclaveName = "axo.deviceKey.enclave"
  private static let softwareName = "axo.deviceKey.software"
  public static let maximumBytes = 32_768
  private static let lifetime: TimeInterval = 24 * 60 * 60

  /// Snapshot only the source's existing identity. An unavailable reference is not absence.
  public static func prepare(
    role: Role, bundleID: String, defaults: UserDefaults, store: any Storing,
    now: Date = .now, transferID: UUID = UUID(), enclave: PhoneDeviceKey.Enclave? = .current
  ) throws -> Outcome {
    guard bundleID == role.sourceBundleID else { throw Failure.wrongIdentity }
    let reference: Data?
    let publicKey: String?
    if let saved = defaults.object(forKey: enclaveName) {
      guard let data = saved as? Data, !data.isEmpty, data.count <= 16_384 else { throw Failure.malformed }
      guard let enclave else { throw Failure.unavailable }
      let signer: any DeviceSigner
      do { signer = try enclave.restore(data) } catch { throw Failure.unavailable }
      // Prove that the source can use its saved reference before publishing it.
      _ = try PhoneDeviceKey.restoreForMigration(data, expectedPublicKey: signer.publicKey, enclave: enclave)
      reference = data
      publicKey = signer.publicKey
    } else {
      guard defaults.object(forKey: softwareName) == nil else { throw Failure.unsupportedSoftwareKey }
      reference = nil
      publicKey = nil
    }
    let created = now.timeIntervalSince1970
    guard created.isFinite, created >= 0 else { throw Failure.malformed }
    let envelope = Envelope(version: 1, transferID: transferID, role: role, sourceBundleID: role.sourceBundleID,
      destinationBundleID: role.destinationBundleID, createdAt: created, reference: reference, publicKey: publicKey)
    let bytes = try JSONEncoder().encode(envelope)
    guard bytes.count <= maximumBytes else { throw Failure.malformed }
    try store.save(bytes, for: role)
    return reference == nil ? .noExistingKey : .prepared
  }

  /// A successful result proves access/signing in this app context, not a completed migration.
  /// Do not persist the restored signer or release account/companion authority from this probe.
  public static func verify(
    role: Role, bundleID: String, defaults: UserDefaults, store: any Storing,
    now: Date = .now, expectedTransferID: UUID? = nil, enclave: PhoneDeviceKey.Enclave? = .current
  ) throws -> Outcome {
    guard let expectedTransferID, bundleID == role.destinationBundleID else { throw Failure.wrongIdentity }
    guard let bytes = try store.load(for: role) else { throw Failure.unavailable }
    let envelope = try parse(bytes, role: role, now: now)
    guard envelope.transferID == expectedTransferID else { throw Failure.wrongIdentity }
    // A pre-existing software identity cannot be silently replaced by an Enclave identity.
    guard defaults.object(forKey: softwareName) == nil else { throw Failure.conflictingDestination }
    let existing = defaults.object(forKey: enclaveName)
    guard let reference = envelope.reference, let expected = envelope.publicKey else {
      guard existing == nil else { throw Failure.conflictingDestination }
      return .noExistingKey
    }
    if let existing {
      guard let data = existing as? Data, !data.isEmpty, let enclave else { throw Failure.conflictingDestination }
      let signer: any DeviceSigner
      do { signer = try enclave.restore(data) } catch { throw Failure.unavailable }
      guard signer.publicKey == expected else { throw Failure.conflictingDestination }
    }
    _ = try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: expected, enclave: enclave)
    return .verified
  }

  private static func parse(_ bytes: Data, role: Role, now: Date) throws -> Envelope {
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.malformed }
    let envelope: Envelope
    do {
      let allowed: Set<String> = ["version", "transferID", "role", "sourceBundleID", "destinationBundleID", "createdAt", "reference", "publicKey"]
      guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        Set(fields.keys).isSubset(of: allowed) else { throw Failure.malformed }
      envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
    } catch { throw Failure.malformed }
    guard envelope.version == 1 else { throw Failure.malformed }
    guard envelope.role == role, envelope.sourceBundleID == role.sourceBundleID,
      envelope.destinationBundleID == role.destinationBundleID else { throw Failure.wrongIdentity }
    let current = now.timeIntervalSince1970
    guard current.isFinite, envelope.createdAt.isFinite, envelope.createdAt >= 0 else { throw Failure.malformed }
    guard envelope.createdAt <= current + 30, current - envelope.createdAt <= lifetime else { throw Failure.expired }
    switch (envelope.reference, envelope.publicKey) {
    case (nil, nil): break
    case (.some(let reference), .some(let publicKey)):
      guard !reference.isEmpty, reference.count <= 16_384, let point = Data(base64Encoded: publicKey),
        point.base64EncodedString() == publicKey,
        (try? P256.Signing.PublicKey(x963Representation: point)) != nil else { throw Failure.malformed }
    default: throw Failure.malformed
    }
    return envelope
  }
}
