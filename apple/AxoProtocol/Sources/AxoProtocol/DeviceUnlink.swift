import Foundation

public struct DeviceUnlink: Codable, Sendable {
  public let accountId: String
  public let hostId: String
  public let linkId: String
  public let expiresAt: UInt64
  public let key: String
  public let managerKey: String
  public var signature: String

  public init(account: UUID, host: UUID, linkID: String, key: String, manager: any DeviceSigner, now: Date = .now) throws {
    accountId = account.uuidString.lowercased(); hostId = host.uuidString.lowercased()
    linkId = linkID; self.key = key; managerKey = manager.publicKey
    expiresAt = UInt64(now.timeIntervalSince1970 * 1000) + 300_000
    signature = ""
    signature = try manager.sign(message()).base64EncodedString()
  }

  public func message() -> Data {
    Data("axo-unlink-device/v1\n\(accountId)\n\(hostId)\n\(linkId)\n\(expiresAt)\n\(key)\n\(managerKey)".utf8)
  }
}
