import AxoClient
import AxoMobileModel
import Foundation
import Security

/// The session token in the Keychain, readable only while the phone is unlocked and never
/// copied to another device or a backup.
struct KeychainTokenStore: SessionTokenStoring {
  private var service: String {
    guard let identity = PhoneStorageIdentity(bundleIdentifier: Bundle.main.bundleIdentifier) else {
      preconditionFailure("Credential storage requires a recognized phone app identity")
    }
    return identity.tokenService
  }
  private let account = "session-token"

  func load() -> SessionToken? { try? loadForCompanion() }

  /// A locked Keychain is unavailable, not a sign-out. The companion must preserve that
  /// distinction when iOS wakes the phone for a Watch recording while its screen is locked.
  func loadForCompanion() throws -> SessionToken? {
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

  func save(_ token: SessionToken) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    // Updating must not first delete a usable credential: a failed write leaves it intact.
    let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
    let item = baseQuery.merging(attributes) { _, new in new }
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }

  func delete() {
    SecItemDelete(baseQuery as CFDictionary)
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

struct KeychainError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
  }
}
