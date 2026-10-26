import AxoClient
import Foundation
import Observation

/// Where the session token is kept between launches: the Keychain on a phone.
public protocol SessionTokenStoring: Sendable {
  func load() -> SessionToken?
  /// Fails if the token could not be kept; the caller must not treat the phone as signed in.
  func save(_ token: SessionToken) throws
  func delete()
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
  /// Why the last sign-in did not take, for the sign-in screen to show.
  public private(set) var signInFailure: String?
  private let store: any SessionTokenStoring

  /// For clients: always reads the current token, so a fresh sign-in is used at once.
  public nonisolated let tokens: any SessionTokenProvider

  public init(store: any SessionTokenStoring) {
    self.store = store
    tokens = StoredSessionToken(store: store)
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
    state = .signedIn
  }

  public func signOut() {
    store.delete()
    state = .signedOut
  }

  /// Call with any error from a relay request; returns whether it signed the phone out.
  @discardableResult
  public func noteFailure(_ error: Error) -> Bool {
    guard (error as? RelayError) == .signInRequired else { return false }
    signOut()
    return true
  }
}

private struct StoredSessionToken: SessionTokenProvider {
  let store: any SessionTokenStoring

  func sessionToken() async throws -> SessionToken {
    guard let token = store.load() else { throw RelayError.signInRequired }
    return token
  }
}
