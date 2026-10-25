import Darwin
import Foundation

public struct UnixSocketPath: Equatable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    let address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard value.hasPrefix("/"),
      !value.utf8.contains(0),
      value.utf8.count < pathCapacity
    else {
      throw AxoClientError.invalidSocketPath
    }
    self.value = value
  }
}
