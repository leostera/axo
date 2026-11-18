import CryptoKit
import Foundation
import Security

/// A device-only bridge. Secret payloads require unlock; the non-secret revocation fence is
/// available after first unlock so source sign-out can invalidate an import while backgrounded.
public struct MobileTransferKeychain: MobileIdentityTransfer.Bridge {
  public static let changeNotification = "dev.leostera.axo.mobile-transfer.changed"
  public static func postChange() {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(rawValue: changeNotification as CFString), nil, nil, true)
  }

  private let group: String
  private let payloadService = "dev.leostera.axo.mobile-transfer.payload.v1"
  private let fenceService = "dev.leostera.axo.mobile-transfer.fence.v1"

  public init(accessGroup: String) throws {
    _ = try EnclaveProbeKeychain(accessGroup: accessGroup)
    group = accessGroup
  }

  public func payload() throws -> Data? {
    var query = query(payloadService)
    query[kSecAttrAccount as String] = "snapshot"
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try checked(status)
    guard let bytes = result as? Data, bytes.count <= MobileIdentityTransfer.maximumBytes else {
      throw MobileIdentityTransfer.Failure.invalid
    }
    return bytes
  }

  public func fence() throws -> MobileIdentityTransfer.Fence? {
    var query = query(fenceService)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try checked(status)
    guard let items = result as? [[String: Any]], items.count == 1,
      let text = items[0][kSecAttrAccount as String] as? String else { throw MobileIdentityTransfer.Failure.invalid }
    return try parseFence(text)
  }

  public func prepare(_ bytes: Data, id: UUID) throws {
    guard try fence() == nil else { throw MobileIdentityTransfer.Failure.conflict }
    let snapshot = try MobileIdentityTransfer.parse(bytes, expectedID: id)
    var query = query(payloadService)
    query[kSecAttrAccount as String] = "snapshot"
    let values: [String: Any] = [kSecValueData as String: bytes,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
    }
    try checked(status)
    var marker = self.query(fenceService)
    marker[kSecAttrAccount as String] = account("ready", id)
    var metadata: [String: String] = ["version": "1"]
    if let token = snapshot.token { metadata["sessionFingerprint"] = Self.fingerprint(token) }
    marker[kSecValueData as String] = try JSONEncoder().encode(metadata)
    marker[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    try checked(SecItemAdd(marker as CFDictionary, nil))
  }

  public static func fingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func boundSessionFingerprint() throws -> String? {
    var query = query(fenceService)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try checked(status)
    guard let bytes = result as? Data, bytes.count <= 1_024,
      let metadata = try? JSONDecoder().decode([String: String].self, from: bytes),
      metadata["version"] == "1", Set(metadata.keys).isSubset(of: ["version", "sessionFingerprint"])
    else { throw MobileIdentityTransfer.Failure.invalid }
    if let value = metadata["sessionFingerprint"] {
      guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
        throw MobileIdentityTransfer.Failure.invalid
      }
    }
    return metadata["sessionFingerprint"]
  }

  public func consume(_ id: UUID) throws -> Bool {
    var query = query(fenceService)
    query[kSecAttrAccount as String] = account("ready", id)
    let status = SecItemUpdate(query as CFDictionary, [kSecAttrAccount as String: account("consumed", id)] as CFDictionary)
    if status == errSecItemNotFound { return false }
    try checked(status)
    return true
  }

  /// Must succeed before changing/deleting a source credential. Never delete-first.
  public func revokeIfPresent() throws {
    guard let current = try fence() else { return }
    let query = query(fenceService)
    // Match this transfer irrespective of ready/consumed: source sign-out wins either way.
    let status = SecItemUpdate(query as CFDictionary,
      [kSecAttrAccount as String: account("revoked", current.transferID)] as CFDictionary)
    try checked(status)
    // Deleting this owned temporary copy is not source sign-out or container cleanup. If the
    // payload is locked, the durable fence already denies import; remove it on foreground.
    try? discardPayload()
  }

  public func discardConsumedPayload(_ id: UUID) throws {
    guard try fence() == .consumed(id) else { return }
    try discardPayload()
  }

  private func discardPayload() throws {
    var query = query(payloadService)
    query[kSecAttrAccount as String] = "snapshot"
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try checked(status) }
  }

  private func parseFence(_ text: String) throws -> MobileIdentityTransfer.Fence {
    let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count == 2, let id = UUID(uuidString: String(pieces[1])),
      id.uuidString.lowercased() == pieces[1] else { throw MobileIdentityTransfer.Failure.invalid }
    switch pieces[0] {
    case "ready": return .ready(id)
    case "consumed": return .consumed(id)
    case "revoked": return .revoked(id)
    default: throw MobileIdentityTransfer.Failure.invalid
    }
  }

  private func account(_ state: String, _ id: UUID) -> String { state + ":" + id.uuidString.lowercased() }

  private func query(_ service: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccessGroup as String: group, kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true]
  }

  private func checked(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw EnclaveProbeKeychain.StorageFailure(status: status) }
  }
}
