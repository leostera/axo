import Foundation
import Security

/// Shared only between explicitly signed source/destination apps on this device. Never syncs.
/// The prefix is supplied from actual provisioning metadata, not guessed from the signing team.
public struct EnclaveProbeKeychain: EnclavePreservationProbe.Storing {
  public struct StorageFailure: Error {
    public let status: Int32
  }

  private let accessGroup: String
  private let service = "dev.leostera.axo.identity-preservation-probe.v1"

  public init(accessGroup: String) throws {
    let suffix = ".dev.leostera.axo.migration"
    let prefix = accessGroup.dropLast(suffix.count)
    guard accessGroup.hasSuffix(suffix), prefix.utf8.count == 10,
      prefix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
    else { throw EnclavePreservationProbe.Failure.wrongIdentity }
    self.accessGroup = accessGroup
  }

  public func load(for role: EnclavePreservationProbe.Role) throws -> Data? {
    var query = query(for: role)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw StorageFailure(status: status) }
    guard let data = result as? Data, data.count <= EnclavePreservationProbe.maximumBytes else {
      throw EnclavePreservationProbe.Failure.malformed
    }
    return data
  }

  public func save(_ data: Data, for role: EnclavePreservationProbe.Role) throws {
    guard !data.isEmpty, data.count <= EnclavePreservationProbe.maximumBytes else {
      throw EnclavePreservationProbe.Failure.malformed
    }
    let query = query(for: role)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw StorageFailure(status: status) }
  }

  private func query(for role: EnclavePreservationProbe.Role) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: role.rawValue,
      kSecAttrAccessGroup as String: accessGroup,
      kSecAttrSynchronizable as String: false,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }
}
