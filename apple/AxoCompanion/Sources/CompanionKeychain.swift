import Foundation
import Security

public protocol CompanionLoginStoring: Sendable {
  func load() throws -> CompanionLoginState
  func save(_ state: CompanionLoginState) throws
}

/// Watch-local, not synchronizable and never included in a backup. Replace atomically: a failed
/// Keychain write must not first erase a working sign-in or report an unstored one as connected.
public struct CompanionKeychainStore: CompanionLoginStoring {
  public init() {}

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "dev.leostera.axo.watch.companion",
     kSecAttrAccount as String: "phone-login"]
  }

  public func load() throws -> CompanionLoginState {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return CompanionLoginState() }
    guard status == errSecSuccess else { throw CompanionError.storage(status) }
    guard let data = result as? Data, data.count <= 8192 else { throw CompanionError.invalidMessage }
    return try JSONDecoder().decode(CompanionLoginState.self, from: data)
  }

  public func save(_ state: CompanionLoginState) throws {
    let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(state),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw CompanionError.storage(status) }
  }
}
