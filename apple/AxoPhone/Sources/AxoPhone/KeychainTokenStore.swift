import AxoClient
import AxoPhoneModel
import Foundation
import Security

/// The Access token in the Keychain, readable only while the phone is unlocked and never
/// copied to another device or a backup.
struct KeychainTokenStore: AccessTokenStoring {
  private let service = "dev.leostera.axo.phone.access"
  private let account = "cf-access-token"

  func load() -> AccessToken? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, let text = String(data: data, encoding: .utf8)
    else { return nil }
    return AccessToken(text)
  }

  func save(_ token: AccessToken) throws {
    delete()
    var item = baseQuery
    item[kSecValueData as String] = Data(token.value.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
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
