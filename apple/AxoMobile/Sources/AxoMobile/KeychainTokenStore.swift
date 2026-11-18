import AxoClient
import AxoMobileModel
import Foundation
import Security

/// This app's original credential namespace remains first in its signed access groups.
struct KeychainTokenStore: SessionTokenStoring {
  private var service: String {
    guard let identity = PhoneStorageIdentity(bundleIdentifier: Bundle.main.bundleIdentifier) else {
      preconditionFailure("Credential storage requires a recognized phone app identity")
    }
    return identity.tokenService
  }
  private let account = "session-token"

  func load() -> SessionToken? { try? loadForCompanion() }

  /// A locked Keychain is unavailable, not sign-out. A durably revoked transferred credential
  /// is absent even if a locked original item has not yet been physically removed.
  func loadForCompanion() throws -> SessionToken? {
    guard let token = try savedToken() else { return nil }
    return try migrationRevoked(token) ? nil : token
  }

  func migrationSessionRevoked() throws -> Bool {
    guard let token = try savedToken() else { return false }
    return try migrationRevoked(token)
  }

  func save(_ token: SessionToken) throws {
    try invalidateTransferBeforeCredentialChange()
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updated != errSecSuccess {
      guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
      let added = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
    if MobileTransferConfiguration.requested {
      let config = try MobileTransferConfiguration.current()
      if config.mode == .destination {
        // During import the receipt is staged, so this does not detach its source binding.
        // A later explicit sign-in owns an independent session, after its credential was saved.
        try MobileTransferJournal(accessGroup: config.accessGroup).detachCompletedSession()
      }
    }
    MobileTransferKeychain.postChange()
  }

  func delete() throws {
    try invalidateTransferBeforeCredentialChange()
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    if MobileTransferConfiguration.requested {
      let config = try MobileTransferConfiguration.current()
      if config.mode == .destination {
        try MobileTransferJournal(accessGroup: config.accessGroup).detachCompletedSession()
      }
    }
    MobileTransferKeychain.postChange()
  }

  private func invalidateTransferBeforeCredentialChange() throws {
    guard MobileTransferConfiguration.requested else { return }
    let config = try MobileTransferConfiguration.current()
    if config.mode == .destination {
      let journal = try MobileTransferJournal(accessGroup: config.accessGroup)
      guard let data = try journal.load() else { return }
      let receipt = try MobileIdentityTransfer.readJournal(data)
      // Saving a staged import is not a new login or a source sign-out.
      guard receipt.completed, receipt.sessionOwnership == .transferred else { return }
    }
    try MobileTransferKeychain(accessGroup: config.accessGroup).revokeIfPresent()
    MobileTransferKeychain.postChange()
  }

  private func migrationRevoked(_ token: SessionToken) throws -> Bool {
    guard MobileTransferConfiguration.requested else { return false }
    let config = try MobileTransferConfiguration.current()
    if config.mode == .destination {
      guard let bytes = try MobileTransferJournal(accessGroup: config.accessGroup).load() else { return false }
      let receipt = try MobileIdentityTransfer.readJournal(bytes)
      guard receipt.completed, receipt.sessionOwnership == .transferred else { return false }
    }
    let bridge = try MobileTransferKeychain(accessGroup: config.accessGroup)
    guard case .revoked = try bridge.fence() else { return false }
    return try bridge.boundSessionFingerprint() == MobileTransferKeychain.fingerprint(token.value)
  }

  private func savedToken() throws -> SessionToken? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status: status) }
    guard let data = item as? Data, let text = String(data: data, encoding: .utf8), let token = SessionToken(text)
    else { throw KeychainError(status: errSecDecode) }
    return token
  }

  private var baseQuery: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account]
  }
}

struct KeychainError: LocalizedError {
  let status: OSStatus
  var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
  }
}
