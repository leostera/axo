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
    defaults.set(authentication.session?.accountID.uuidString, forKey: prefix + "account")
    return snapshot
  }

  /// Local transcription only: matching this non-secret metadata never grants a token or
  /// access to Axo. It lets a cold, locked iPhone process recognize the already signed-in Watch.
  func matchesPublishedVoiceIdentity(_ request: CompanionVoiceRequest, now: Date = .now) -> Bool {
    request.isFresh(now: now)
      && defaults.string(forKey: prefix + "fingerprint") == request.signInFingerprint
      && defaults.string(forKey: prefix + "account").flatMap(UUID.init(uuidString:)) == request.accountID
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
  private let voice: PhoneVoiceTranscription

  public init(authentication: @escaping @MainActor () async throws -> CompanionAuthentication,
    transcribeAudio: @escaping @Sendable (URL) async throws -> String = { _ in throw CompanionVoiceFailure.unsupported }
  ) {
    self.authentication = authentication
    voice = PhoneVoiceTranscription(authentication: authentication, transcribe: transcribeAudio)
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
      voice.authenticationChanged(snapshot.authentication)
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
        self.voice.authenticationChanged(snapshot.authentication)
        let reply = CompanionSyncReply(requestID: request.requestID, snapshot: snapshot)
        replyHandler([companionPayloadKey: try JSONEncoder().encode(reply)])
      } catch { replyHandler([:]) }
    }
  }

  public nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
    // Acknowledge receipt immediately; speech results have their own authenticated reply.
    replyHandler(Data())
    guard let (request, copy) = PhoneVoiceTranscription.receivePacket(messageData) else { return }
    Task { @MainActor in self.voice.receive(request, audio: copy, session: session) }
  }

  public nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
    guard let (request, copy) = PhoneVoiceTranscription.receiveFile(file) else { return }
    Task { @MainActor in self.voice.receive(request, audio: copy, session: session) }
  }

  public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { receiveVoiceCancel(userInfo) }
  public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receiveVoiceCancel(message) }

  private nonisolated func receiveVoiceCancel(_ message: [String: Any]) {
    guard let text = message[companionVoiceCancelKey] as? String, let id = UUID(uuidString: text) else { return }
    Task { @MainActor in self.voice.cancel(id) }
  }

  public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  public nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
#endif
