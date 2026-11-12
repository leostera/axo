import AxoClient
import AxoPhoneModel
import AxoProtocol
import Foundation
import Observation

/// A dictation belongs to this account, host generation, and existing Session, never whatever
/// happens to be selected when Apple's input sheet finishes or a network request returns.
public struct WatchChatTarget: Codable, Hashable, Sendable {
  public let accountID: UUID
  public let host: RemoteHostRef
  public let session: SessionID

  public init(accountID: UUID, host: RemoteHostRef, session: SessionID) {
    self.accountID = accountID
    self.host = host
    self.session = session
  }

  public func resolve(in hosts: [RemoteHost], account: UUID) -> RemoteSession? {
    guard accountID == account, let host = hosts.first(where: { $0.reference == self.host }) else { return nil }
    return host.sessions.first { $0.sessionId == session && $0.hasAgent != false }
  }
}

public struct WatchVoiceDraft: Equatable, Sendable {
  public let target: WatchChatTarget
  public let text: String

  public init?(text: String, target: WatchChatTarget) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    self.text = text
    self.target = target
  }
}

@MainActor
@Observable
public final class WatchChatModel {
  public let accountID: UUID
  public let workbench: PhoneWorkbench
  public let account: AccountSession
  public private(set) var target: WatchChatTarget?
  public private(set) var draft: WatchVoiceDraft?
  public private(set) var failure: String?
  private let defaults: UserDefaults
  private let selectionKey: String
  private var started = false

  public init(accountID: UUID, workbench: PhoneWorkbench, account: AccountSession, defaults: UserDefaults = .standard) {
    self.accountID = accountID
    self.workbench = workbench
    self.account = account
    self.defaults = defaults
    selectionKey = "axo.watch.chat.\(accountID.uuidString.lowercased())"
    if let bytes = defaults.data(forKey: selectionKey),
      let stored = try? JSONDecoder().decode(WatchChatTarget.self, from: bytes), stored.accountID == accountID {
      target = stored
    }
  }

  public convenience init(token: SessionToken, defaults: UserDefaults = .standard) {
    let account = AccountSession(store: WatchRuntimeTokenStore(token))
    let profile = AccountClient(tokens: account.tokens)
    let key = "axo.watch.client-id"
    let clientID: ClientID
    if let text = defaults.string(forKey: key), let stored = ClientID(rawValue: text) { clientID = stored }
    else {
      clientID = ClientID(rawValue: "watch-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())!
      defaults.set(clientID.rawValue, forKey: key)
    }
    let feed = AccountConnection(clientID: clientID, tokens: account.tokens)
    let workbench = PhoneWorkbench(hosts: HostsModel(profile: profile), feed: feed, account: account, makeWorkbench: { host in
      HostWorkbenchModel(host: host, connection: HostConnection(account: feed, host: host.reference), feed: feed, account: account)
    })
    self.init(accountID: token.accountID, workbench: workbench, account: account, defaults: defaults)
  }

  public var selectedSession: RemoteSession? { target?.resolve(in: workbench.hosts.hosts, account: accountID) }
  public var selectedHost: RemoteHost? { workbench.hosts.hosts.first { $0.reference == target?.host } }
  public var chat: Chat? {
    guard let target, selectedSession != nil, workbench.selection?.session == target.session,
      workbench.current?.reference == target.host else { return nil }
    return workbench.current?.chat(target.session)
  }
  public var canSend: Bool {
    account.state == .signedIn && workbench.link == .connected && selectedHost?.status == .online
      && selectedSession != nil && draft != nil && draft?.target == target && !workbench.isSending
  }

  public func start() async {
    if started { await workbench.resume(); return }
    started = true
    await workbench.start()
    reconcile()
  }

  /// Called when the account listing changes. Never silently fall back to a different Session.
  public func reconcile() {
    guard let target, selectedSession != nil else { return }
    if workbench.selection?.host != target.host.hostId || workbench.selection?.session != target.session
      || workbench.current?.reference != target.host {
      workbench.select(host: target.host.hostId, session: target.session)
    }
    chat?.feed.animates = false
  }

  @discardableResult
  public func select(host: RemoteHost, session: RemoteSession) -> Bool {
    guard !workbench.isSending else { return false }
    let target = WatchChatTarget(accountID: accountID, host: host.reference, session: session.sessionId)
    guard target.resolve(in: workbench.hosts.hosts, account: accountID) != nil else { return false }
    // Selection is explicit. Words dictated for the old Session cannot follow it.
    draft = nil
    failure = nil
    self.target = target
    if let bytes = try? JSONEncoder().encode(target) { defaults.set(bytes, forKey: selectionKey) }
    reconcile()
    return true
  }

  @discardableResult
  public func acceptTranscript(_ text: String, for target: WatchChatTarget) -> Bool {
    guard account.state == .signedIn, target == self.target, selectedSession != nil, !workbench.isSending,
      let draft = WatchVoiceDraft(text: text, target: target) else { return false }
    self.draft = draft
    failure = nil
    return true
  }

  public func discardDraft() { if !workbench.isSending { draft = nil } }

  public func send() async {
    guard canSend, let draft, let target, draft.target == target,
      workbench.selection == PhoneWorkbench.Selection(host: target.host.hostId, session: target.session),
      workbench.current?.reference == target.host else { return }
    workbench.setDraft(draft.text, for: PhoneWorkbench.Selection(host: target.host.hostId, session: target.session))
    // Do not interrupt work someone started on the Mac. The shared model keeps one commandId
    // across uncertain retries, so a reconnect cannot duplicate the dictated prompt.
    let outcome = await workbench.send(delivery: .followUp)
    guard self.target == target else { return }
    switch outcome {
    case .sent:
      self.draft = nil
      failure = nil
    case .uncertain:
      self.draft = nil
      failure = "Delivery not confirmed. Axo is checking—do not resend."
    case .failed:
      failure = workbench.current?.failure ?? "Not sent. Your transcript is still here."
    }
  }

  public func suspend() { workbench.suspend() }
  public func stop() {
    draft = nil
    workbench.stop()
    account.signOut() // clears only this runtime's token copy, not the shared phone Keychain sign-in
  }
}

private final class WatchRuntimeTokenStore: SessionTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var token: SessionToken?
  init(_ token: SessionToken) { self.token = token }
  func load() -> SessionToken? { lock.lock(); defer { lock.unlock() }; return token }
  func save(_ token: SessionToken) throws { throw AxoClientError.invalidResponse("Manage this sign-in on the iPhone") }
  func delete() { lock.lock(); defer { lock.unlock() }; token = nil }
}
