import Foundation
import Observation

@MainActor
@Observable
public final class WatchCompanionModel {
  public enum Status: Equatable {
    case waitingForPhone, signedOut, checking, verified(CompanionAccount), offline(String), inactive
  }

  public private(set) var status: Status = .waitingForPhone
  public private(set) var login = CompanionLoginState()
  private let store: any CompanionLoginStoring
  private let checkAccount: @Sendable (CompanionSession) async throws -> CompanionAccount
  private var generation: UInt64 = 0
  private var active = false
  private var loaded = false
  private var needsLivePhone = false

  public init(store: any CompanionLoginStoring = CompanionKeychainStore(),
    checkAccount: @escaping @Sendable (CompanionSession) async throws -> CompanionAccount = { try await CompanionAccountClient().account(using: $0) }
  ) {
    self.store = store
    self.checkAccount = checkAccount
  }

  public func setActive(_ active: Bool) {
    self.active = active
    generation &+= 1
    if !active { status = .inactive }
  }

  public func load() {
    guard !loaded else { return }
    do { login = try store.load(); loaded = true }
    catch { status = .offline(error.localizedDescription) }
  }

  public func receive(_ snapshot: CompanionSnapshot, authoritative: Bool) async {
    load()
    guard loaded else { return }
    if !authoritative, login.snapshot?.authority != snapshot.authority {
      // Contexts from a new/reinstalled phone are hints, never a fresh grant of authority.
      generation &+= 1
      needsLivePhone = true
      status = .waitingForPhone
      return
    }
    if authoritative { needsLivePhone = false }
    var next = login
    guard next.receive(snapshot, authoritative: authoritative) else {
      if authoritative { await refresh() }
      return
    }
    generation &+= 1
    // Clear the old in-memory account before a fallible write or HTTP request.
    login = CompanionLoginState()
    do {
      try store.save(next)
      login = next
      await refresh()
    } catch { status = .offline(error.localizedDescription) }
  }

  /// Chat sockets use the same credential; a refusal there invalidates the cached login too.
  public func authorizationRefused() {
    generation &+= 1
    login.invalidate()
    do { try store.save(login); status = .signedOut }
    catch { status = .offline(error.localizedDescription) }
  }

  public func refresh() async {
    guard active else { return }
    load()
    guard loaded else { return }
    guard !needsLivePhone else { status = .waitingForPhone; return }
    guard let session = login.session else {
      status = login.snapshot == nil ? .waitingForPhone : .signedOut
      return
    }
    generation &+= 1
    let requestGeneration = generation
    status = .checking
    do {
      let account = try await checkAccount(session)
      guard active, generation == requestGeneration, !Task.isCancelled else { return }
      guard account.accountId == session.accountID else { throw CompanionError.invalidMessage }
      status = .verified(account)
    } catch {
      guard active, generation == requestGeneration, !Task.isCancelled else { return }
      if case CompanionError.unauthorized = error {
        authorizationRefused()
      } else { status = .offline(error.localizedDescription) }
    }
  }
}
