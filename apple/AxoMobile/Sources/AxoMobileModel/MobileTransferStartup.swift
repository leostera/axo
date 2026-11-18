import Foundation
import Security

public struct MobileTransferConfiguration {
  public enum Mode: String { case source, destination }
  public let mode: Mode
  public let accessGroup: String

  public init(bundleID: String?, mode: Any?, accessGroup: Any?, scope: Any?) throws {
    guard let text = mode as? String, let parsed = Mode(rawValue: text),
      bundleID == (parsed == .source ? "dev.leostera.axo.phone" : "dev.leostera.axo"),
      let group = accessGroup as? String,
      parsed == .source || scope as? String == "mobile-only" else { throw MobileIdentityTransfer.Failure.invalid }
    _ = try MobileTransferKeychain(accessGroup: group)
    self.mode = parsed; self.accessGroup = group
  }

  private static func configured(_ key: String) -> Any? {
    #if DEBUG && targetEnvironment(simulator)
      let fixtures = ["AXOIdentityMigrationMode": "AXO_IDENTITY_MIGRATION_MODE",
        "AXOIdentityMigrationAccessGroup": "AXO_IDENTITY_MIGRATION_ACCESS_GROUP",
        "AXOIdentityMigrationScope": "AXO_IDENTITY_MIGRATION_SCOPE"]
      if let name = fixtures[key], let value = ProcessInfo.processInfo.environment[name] { return value }
    #endif
    return Bundle.main.object(forInfoDictionaryKey: key)
  }

  public static var requested: Bool {
    ["AXOIdentityMigrationMode", "AXOIdentityMigrationAccessGroup", "AXOIdentityMigrationScope"]
      .contains { configured($0) != nil }
  }

  public static func current() throws -> MobileTransferConfiguration {
    guard !EnclaveProbeRuntime.requested else { throw MobileIdentityTransfer.Failure.invalid }
    return try MobileTransferConfiguration(bundleID: Bundle.main.bundleIdentifier,
      mode: configured("AXOIdentityMigrationMode"),
      accessGroup: configured("AXOIdentityMigrationAccessGroup"),
      scope: configured("AXOIdentityMigrationScope"))
  }

  public static var requiresDestinationGate: Bool {
    guard Bundle.main.bundleIdentifier == "dev.leostera.axo" else { return requested && Bundle.main.bundleIdentifier != "dev.leostera.axo.phone" }
    do {
      if !requested {
        // Removing the staging flag must not release a partially applied destination.
        guard let bytes = try MobileTransferJournal().load() else { return false }
        return try !MobileIdentityTransfer.readJournal(bytes).completed
      }
      let config = try current()
      guard config.mode == .destination,
        let bytes = try MobileTransferJournal(accessGroup: config.accessGroup).load(),
        try MobileIdentityTransfer.readJournal(bytes).completed else { return true }
      return false
    } catch { return true }
  }
}

/// The destination's private journal, not the shared source envelope. Staged data is secret and
/// requires unlock; a completed receipt contains only correlation/ownership metadata.
public struct MobileTransferJournal {
  private let group: String?
  private let service = "dev.leostera.axo.mobile-transfer.journal.v1"

  public init() { group = nil }

  public init(accessGroup: String) throws {
    _ = try MobileTransferKeychain(accessGroup: accessGroup)
    group = String(accessGroup.dropLast("dev.leostera.axo.migration".count)) + "dev.leostera.axo"
  }

  public func load() throws -> Data? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try checked(status)
    guard let bytes = result as? Data else { throw MobileIdentityTransfer.Failure.invalid }
    _ = try MobileIdentityTransfer.readJournal(bytes)
    return bytes
  }

  public func save(_ bytes: Data) throws {
    let journal = try MobileIdentityTransfer.readJournal(bytes)
    let attributes: [String: Any] = [kSecValueData as String: bytes,
      kSecAttrAccessible as String: journal.completed
        ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound { status = SecItemAdd(base.merging(attributes) { _, new in new } as CFDictionary, nil) }
    try checked(status)
  }

  /// A new explicit sign-in owns a new session. Never detach a staged/incomplete import.
  public func detachCompletedSession() throws {
    guard let data = try load() else { return }
    let journal = try MobileIdentityTransfer.readJournal(data)
    guard journal.completed else { return }
    try save(JSONEncoder().encode(MobileIdentityTransfer.Journal(transferID: journal.transferID,
      staged: nil, sessionOwnership: .independent)))
  }

  private var base: [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "receipt", kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true]
    if let group { query[kSecAttrAccessGroup as String] = group }
    return query
  }
  private func checked(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw EnclaveProbeKeychain.StorageFailure(status: status) }
  }
}
