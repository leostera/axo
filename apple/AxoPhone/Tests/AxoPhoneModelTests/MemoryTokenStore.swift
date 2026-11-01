import AxoClient
import AxoPhoneModel
import Foundation

/// A token store in memory, for tests: the Keychain's, without the Keychain.
final class MemoryTokenStore: SessionTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var token: SessionToken?
  init(_ token: SessionToken? = nil) { self.token = token }
  func load() -> SessionToken? { lock.withLock { token } }
  var failsToSave = false
  func save(_ token: SessionToken) throws {
    if failsToSave { throw NSError(domain: "keychain", code: -34018) }
    lock.withLock { self.token = token }
  }
  func delete() { lock.withLock { token = nil } }
}
