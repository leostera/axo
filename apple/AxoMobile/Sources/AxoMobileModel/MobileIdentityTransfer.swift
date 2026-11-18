import AxoClient
import AxoProtocol
import CryptoKit
import Foundation

/// Device-local mobile transfer values. Never encode these in a harness report or a log.
public enum MobileIdentityTransfer {
  public enum Failure: Error, Equatable {
    case invalid, unavailable, expired, conflict, revoked, pendingWork, alreadyCompleted
  }
  public static let maximumBytes = 1_048_576
  public static let enclaveKey = "axo.deviceKey.enclave"
  public static let softwareKey = "axo.deviceKey.software"

  public struct Identity: Codable, Equatable {
    public let reference: Data
    public let publicKey: String
  }

  public struct Snapshot: Codable {
    public let version: Int
    public let transferID: UUID
    public let source: String
    public let destination: String
    public let createdAt: TimeInterval
    public let token: String?
    public let identity: Identity?
    /// Each value is one bounded property-list value, not an unrestricted defaults dump.
    public let preferences: [String: Data]

    public var session: SessionToken? { token.flatMap(SessionToken.init) }
  }

  public enum Fence: Equatable {
    case ready(UUID), consumed(UUID), revoked(UUID)
    public var transferID: UUID {
      switch self { case .ready(let id), .consumed(let id), .revoked(let id): id }
    }
  }

  public struct Journal: Codable {
    public enum SessionOwnership: String, Codable { case transferred, independent }
    public let schema: Int
    public let transferID: UUID
    public let sessionOwnership: SessionOwnership
    /// Present only while applying. Completion removes all credentials and key references.
    public let staged: Data?
    public var completed: Bool { staged == nil }
    public init(transferID: UUID, staged: Data?, sessionOwnership: SessionOwnership = .transferred) {
      schema = 1
      self.transferID = transferID; self.staged = staged; self.sessionOwnership = sessionOwnership
    }
  }

  public protocol Bridge {
    func payload() throws -> Data?
    func fence() throws -> Fence?
    /// An atomic compare-and-swap: only ready(id) may become consumed(id).
    func consume(_ id: UUID) throws -> Bool
    func discardConsumedPayload(_ id: UUID) throws
  }

  public protocol Destination {
    var defaults: UserDefaults { get }
    func token() throws -> SessionToken?
    func saveToken(_ token: SessionToken) throws
    func journal() throws -> Data?
    func saveJournal(_ data: Data) throws
  }

  private static let preferenceKeys: Set<String> = [
    "appearance", "accentColor", "sidebar.pinnedSessions.v1", "sidebar.seenSessions.v1",
    "sidebar.seenSessionsBaseline.v1", "sidebar.grouping.v1", "axo.companion.v1.authority",
    "axo.companion.v1.revision", "axo.companion.v1.fingerprint", "axo.companion.v1.account",
    InputKeyPins.defaultsKey,
  ]

  public static func export(
    defaults: UserDefaults, token: SessionToken?, transferID: UUID, now: Date = .now,
    enclave: PhoneDeviceKey.Enclave? = .current
  ) throws -> Data {
    let identity: Identity?
    if let saved = defaults.object(forKey: enclaveKey) {
      guard let reference = saved as? Data, !reference.isEmpty, reference.count <= 16_384,
        let enclave else { throw Failure.unavailable }
      let signer = try enclave.restore(reference)
      _ = try PhoneDeviceKey.restoreForMigration(reference, expectedPublicKey: signer.publicKey, enclave: enclave)
      identity = Identity(reference: reference, publicKey: signer.publicKey)
    } else {
      guard defaults.object(forKey: softwareKey) == nil else { throw Failure.conflict }
      identity = nil
    }
    var preferences: [String: Data] = [:]
    for key in preferenceKeys {
      guard let value = defaults.object(forKey: key) else { continue }
      try checkPreference(key, value: value)
      preferences[key] = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    let snapshot = Snapshot(version: 1, transferID: transferID, source: "dev.leostera.axo.phone",
      destination: "dev.leostera.axo", createdAt: now.timeIntervalSince1970,
      token: token?.value, identity: identity, preferences: preferences)
    let bytes = try JSONEncoder().encode(snapshot)
    _ = try parse(bytes, expectedID: transferID, now: now)
    return bytes
  }

  public static func parse(_ data: Data, expectedID: UUID, now: Date = .now) throws -> Snapshot {
    guard !data.isEmpty, data.count <= maximumBytes,
      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(raw.keys).isSubset(of: ["version", "transferID", "source", "destination", "createdAt", "token", "identity", "preferences"]),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data), snapshot.version == 1,
      snapshot.transferID == expectedID, snapshot.source == "dev.leostera.axo.phone",
      snapshot.destination == "dev.leostera.axo", snapshot.createdAt.isFinite, snapshot.createdAt >= 0,
      snapshot.preferences.count <= 512 else { throw Failure.invalid }
    let current = now.timeIntervalSince1970
    guard current.isFinite, snapshot.createdAt <= current + 30,
      current - snapshot.createdAt <= 86_400 else { throw Failure.expired }
    if let token = snapshot.token { guard SessionToken(token) != nil else { throw Failure.invalid } }
    if let identity = snapshot.identity {
      guard let rawIdentity = raw["identity"] as? [String: Any], Set(rawIdentity.keys) == ["reference", "publicKey"],
        !identity.reference.isEmpty, identity.reference.count <= 16_384,
        let point = Data(base64Encoded: identity.publicKey), point.base64EncodedString() == identity.publicKey,
        (try? P256.Signing.PublicKey(x963Representation: point)) != nil else { throw Failure.invalid }
    }
    for (key, bytes) in snapshot.preferences {
      guard bytes.count <= maximumBytes,
        let value = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
      else { throw Failure.invalid }
      try checkPreference(key, value: value)
    }
    return snapshot
  }

  public static func readJournal(_ data: Data) throws -> Journal {
    guard data.count <= maximumBytes * 2,
      let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(fields.keys).isSubset(of: ["schema", "transferID", "staged", "sessionOwnership"]),
      fields["schema"] as? Int == 1,
      let journal = try? JSONDecoder().decode(Journal.self, from: data),
      journal.completed || journal.sessionOwnership == .transferred else { throw Failure.invalid }
    return journal
  }

  /// The caller authenticates the snapshot's session against the live account before applying.
  /// This synchronous phase rechecks the source fence after that await and before each commit.
  public static func apply(
    snapshot: Snapshot, bytes: Data, bridge: any Bridge, destination: any Destination,
    enclave: PhoneDeviceKey.Enclave? = .current
  ) throws {
    let snapshot = try parse(bytes, expectedID: snapshot.transferID)
    let id = snapshot.transferID
    guard try bridge.fence() == .ready(id) || bridge.fence() == .consumed(id) else { throw Failure.revoked }
    if let data = try destination.journal() {
      let journal = try readJournal(data)
      guard !journal.completed else { throw Failure.alreadyCompleted }
      guard journal.transferID == id, journal.staged == bytes else { throw Failure.conflict }
    } else {
      guard try bridge.fence() == .ready(id) else { throw Failure.revoked }
    }
    try checkDestination(snapshot, destination: destination, enclave: enclave)
    try destination.saveJournal(JSONEncoder().encode(Journal(transferID: id, staged: bytes)))
    // No account/workbench/companion exists while this journal is staged.
    if let identity = snapshot.identity { destination.defaults.set(identity.reference, forKey: enclaveKey) }
    for (key, bytes) in snapshot.preferences {
      let value = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
      destination.defaults.set(value, forKey: key)
    }
    guard destination.defaults.synchronize() else { throw Failure.unavailable }
    if let token = snapshot.session { try destination.saveToken(token) }
    try checkDestination(snapshot, destination: destination, enclave: enclave)
    guard try destination.token() == snapshot.session else { throw Failure.unavailable }
    if let identity = snapshot.identity {
      guard destination.defaults.data(forKey: enclaveKey) == identity.reference else { throw Failure.unavailable }
    }
    for (key, bytes) in snapshot.preferences {
      guard let value = destination.defaults.object(forKey: key), try same(value, bytes) else { throw Failure.unavailable }
    }
    if try !bridge.consume(id) {
      guard try bridge.fence() == .consumed(id) else { throw Failure.revoked }
    }
    try destination.saveJournal(JSONEncoder().encode(Journal(transferID: id, staged: nil)))
    // Sanitizing the shared copy is best effort after durable completion. A consumed fence
    // and completed receipt already prohibit re-import; no completion receipt retains secrets.
    try? bridge.discardConsumedPayload(id)
  }

  private static func checkDestination(
    _ snapshot: Snapshot, destination: any Destination, enclave: PhoneDeviceKey.Enclave?
  ) throws {
    let defaults = destination.defaults
    guard defaults.object(forKey: softwareKey) == nil else { throw Failure.conflict }
    if let identity = snapshot.identity {
      _ = try PhoneDeviceKey.restoreForMigration(identity.reference, expectedPublicKey: identity.publicKey, enclave: enclave)
      if let saved = defaults.object(forKey: enclaveKey) {
        guard let saved = saved as? Data, let enclave else { throw Failure.conflict }
        guard try enclave.restore(saved).publicKey == identity.publicKey else { throw Failure.conflict }
      }
    } else if defaults.object(forKey: enclaveKey) != nil { throw Failure.conflict }
    if let token = try destination.token(), token != snapshot.session { throw Failure.conflict }
    for (key, bytes) in snapshot.preferences {
      if let value = defaults.object(forKey: key), try !same(value, bytes) { throw Failure.conflict }
    }
  }

  private static func same(_ value: Any, _ bytes: Data) throws -> Bool {
    let expected = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
    return (value as? NSObject)?.isEqual(expected) == true
  }

  private static func checkPreference(_ key: String, value: Any) throws {
    guard preferenceKeys.contains(key) else { throw Failure.invalid }
    if key == InputKeyPins.defaultsKey {
      guard let keys = value as? [String], keys.count <= InputKeyPins.limit, Set(keys).count == keys.count,
        keys.allSatisfy({ key in
          guard let point = Data(base64Encoded: key), point.base64EncodedString() == key else { return false }
          return (try? P256.KeyAgreement.PublicKey(x963Representation: point)) != nil
        })
      else { throw Failure.invalid }
    } else if key == "sidebar.pinnedSessions.v1" {
      guard let values = value as? [String], values.count <= 256, Set(values).count == values.count,
        values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw Failure.invalid }
    } else if key == "sidebar.seenSessions.v1" {
      guard let values = value as? [String: NSNumber], values.count <= 4_096,
        values.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.doubleValue.isFinite && $0.value.doubleValue >= 0 })
      else { throw Failure.invalid }
    } else if key == "sidebar.grouping.v1" {
      guard let bytes = value as? Data, bytes.count <= 16_384 else { throw Failure.invalid }
    } else if key == "sidebar.seenSessionsBaseline.v1" || key == "axo.companion.v1.revision" {
      guard let number = value as? NSNumber, number.doubleValue.isFinite,
        number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
        number.doubleValue <= Double(Int64.max) else { throw Failure.invalid }
    } else {
      guard let text = value as? String, text.utf8.count <= 1_024 else { throw Failure.invalid }
      if key == "appearance" { guard ["system", "light", "dark"].contains(text) else { throw Failure.invalid } }
      if key == "axo.companion.v1.authority" || key == "axo.companion.v1.account" {
        guard UUID(uuidString: text) != nil else { throw Failure.invalid }
      }
    }
  }
}
