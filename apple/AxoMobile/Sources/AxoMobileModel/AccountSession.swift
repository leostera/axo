import AxoClient
import Foundation
import Observation

/// Where the session token is kept between launches: the Keychain on a phone.
public protocol SessionTokenStoring: Sendable {
  func load() -> SessionToken?
  /// Fails if the token could not be kept; the caller must not treat the phone as signed in.
  func save(_ token: SessionToken) throws
  func delete() throws
}

/// Whether this phone is signed in, and the token its requests carry.
///
/// Signing in is the only way in: there is no other account state. A request the relay refuses as
/// unauthenticated signs the phone out, so the next screen is the sign-in, not a loop of errors.
@MainActor
@Observable
public final class AccountSession {
  public enum State: Equatable, Sendable {
    case signedOut
    case signedIn
  }

  public private(set) var state: State
  /// Changes on every successful sign-in or sign-out, including a switch between accounts.
  public private(set) var credentialRevision = UUID()
  /// Explicit sign-out wins over a later foreground restore of previously unavailable storage.
  public private(set) var hasEndedSession = false
  /// Why the last sign-in did not take, for the sign-in screen to show.
  public private(set) var signInFailure: String?
  private let store: any SessionTokenStoring
  private let tokenAccess: StoredSessionToken

  /// For clients: always reads the current token, so a fresh sign-in is used at once.
  public nonisolated let tokens: any SessionTokenProvider

  public init(store: any SessionTokenStoring) {
    self.store = store
    let access = StoredSessionToken(store: store)
    tokenAccess = access
    tokens = access
    state = store.load() == nil ? .signedOut : .signedIn
  }

  /// Keeps `token` and signs in. If it cannot be kept the phone stays signed out: a token that
  /// is not stored would be gone by the next request and sign the phone straight back out.
  public func signIn(with token: SessionToken) {
    do {
      try store.save(token)
    } catch {
      signInFailure = "Could not keep your sign-in on this device: \(error.localizedDescription)"
      return
    }
    signInFailure = nil
    hasEndedSession = false
    tokenAccess.setEnded(false)
    state = .signedIn
    credentialRevision = UUID()
  }

  @discardableResult
  public func signOut() -> Bool {
    do { try store.delete() }
    catch {
      signInFailure = "Could not end this sign-in securely. Unlock this device and try again."
      return false
    }
    hasEndedSession = true
    tokenAccess.setEnded(true)
    state = .signedOut
    credentialRevision = UUID()
    return true
  }

  /// A transferred session was durably revoked in the other app. No credential is re-imported.
  public func noteTransferredSessionRevoked() {
    hasEndedSession = true
    tokenAccess.setEnded(true)
    state = .signedOut
    credentialRevision = UUID()
  }

  /// A background launch can occur while the Keychain is locked. Restore on foreground once
  /// available, but never undo a sign-out made in this app process.
  public func restoreStoredSession() {
    guard state == .signedOut, !hasEndedSession, store.load() != nil else { return }
    state = .signedIn
    credentialRevision = UUID()
  }

  /// Call with any error from a relay request; returns whether it signed the phone out.
  @discardableResult
  public func noteFailure(_ error: Error) -> Bool {
    guard (error as? RelayError) == .signInRequired else { return false }
    return signOut()
  }
}

private final class StoredSessionToken: SessionTokenProvider, @unchecked Sendable {
  private let store: any SessionTokenStoring
  private let lock = NSLock()
  private var ended = false

  init(store: any SessionTokenStoring) { self.store = store }
  func setEnded(_ value: Bool) { lock.withLock { ended = value } }

  func sessionToken() async throws -> SessionToken {
    try lock.withLock {
      guard !ended, let token = store.load() else { throw RelayError.signInRequired }
      return token
    }
  }
}
