import AxoClient
import AxoMobileModel
import Foundation

/// A token store in memory, for tests: the Keychain's, without the Keychain.
final class MemoryTokenStore: SessionTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var token: SessionToken?
  init(_ token: SessionToken? = nil) { self.token = token }
  /// Reads fail as a locked iPhone's Keychain does (errSecInteractionNotAllowed).
  var isLocked = false
  func load() throws -> SessionToken? {
    if isLocked { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
    return lock.withLock { token }
  }
  var failsToSave = false
  func save(_ token: SessionToken) throws {
    if failsToSave { throw NSError(domain: "keychain", code: -34018) }
    lock.withLock { self.token = token }
  }
  var failsToDelete = false
  func delete() throws {
    if failsToDelete { throw NSError(domain: "keychain", code: -25308) }
    lock.withLock { token = nil }
  }
}
