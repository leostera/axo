import Foundation

/// Stable ordering metadata survives phone process restarts. Defaults contain only a token
/// fingerprint, not the sign-in itself. The real sign-in is read from the phone Keychain.
@MainActor
public final class CompanionSnapshotPublisher {
  private let defaults: UserDefaults
  private let prefix = "axo.companion.v1."

  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func snapshot(for authentication: CompanionAuthentication) throws -> CompanionSnapshot {
    var authority = defaults.string(forKey: prefix + "authority").flatMap(UUID.init(uuidString:)) ?? UUID()
    var revision = (defaults.object(forKey: prefix + "revision") as? NSNumber)?.int64Value ?? 0
    let changed = defaults.string(forKey: prefix + "fingerprint") != authentication.fingerprint
    if revision == Int64.max { authority = UUID(); revision = 0 }
    if changed || revision < 1 { revision += 1 }
    let snapshot = try CompanionSnapshot(authority: authority, revision: revision, authentication: authentication)
    defaults.set(authority.uuidString, forKey: prefix + "authority")
    defaults.set(revision, forKey: prefix + "revision")
    defaults.set(authentication.fingerprint, forKey: prefix + "fingerprint")
    return snapshot
  }
}

#if os(iOS) || os(watchOS)
struct CompanionSyncRequest: Codable { let requestID: UUID }
struct CompanionSyncReply: Codable { let requestID: UUID; let snapshot: CompanionSnapshot }
let companionPayloadKey = "axo.companion.login.v1"

func companionBytes(_ message: [String: Any]) -> Data? {
  guard let bytes = message[companionPayloadKey] as? Data, bytes.count <= 8192 else { return nil }
  return bytes
}
#endif

#if os(iOS)
import WatchConnectivity

/// The one iPhone app owns WCSession; installing it is all the Watch needs. A live request reads
/// the current Keychain sign-in, including while the iPhone app has been woken in the background.
@MainActor
public final class PhoneCompanionSignIn: NSObject, WCSessionDelegate {
  private let authentication: @MainActor () async throws -> CompanionAuthentication
  private let publisher: CompanionSnapshotPublisher
  private let session: WCSession?

  public init(authentication: @escaping @MainActor () async throws -> CompanionAuthentication) {
    self.authentication = authentication
    publisher = CompanionSnapshotPublisher()
    session = WCSession.isSupported() ? WCSession.default : nil
    super.init()
    session?.delegate = self
    session?.activate()
  }

  public func refresh() async {
    guard let session, session.activationState == .activated, session.isPaired else { return }
    do {
      let snapshot = try publisher.snapshot(for: await authentication())
      try session.updateApplicationContext([companionPayloadKey: JSONEncoder().encode(snapshot)])
    } catch {
      // Never publish a false sign-out because the phone Keychain is temporarily locked.
      // A foreground refresh or a live Watch request retries without exposing error payloads.
    }
  }

  public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    Task { @MainActor in await self.refresh() }
  }

  public nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in await self.refresh() }
  }

  public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    guard let bytes = companionBytes(message), let request = try? JSONDecoder().decode(CompanionSyncRequest.self, from: bytes) else {
      replyHandler([:]); return
    }
    Task { @MainActor in
      do {
        let snapshot = try self.publisher.snapshot(for: await self.authentication())
        let reply = CompanionSyncReply(requestID: request.requestID, snapshot: snapshot)
        replyHandler([companionPayloadKey: try JSONEncoder().encode(reply)])
      } catch { replyHandler([:]) }
    }
  }

  public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  public nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
