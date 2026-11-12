#if os(watchOS)
import Foundation
import Observation
import WatchConnectivity

@MainActor
@Observable
public final class WatchCompanionSignIn: NSObject, WCSessionDelegate {
  public let model = WatchCompanionModel()
  public private(set) var phoneReachable = false
  public private(set) var companionInstalled = false
  private let session: WCSession?
  private var requestID: UUID?
  private var active = false

  public override init() {
    session = WCSession.isSupported() ? WCSession.default : nil
    super.init()
    session?.delegate = self
    session?.activate()
  }

  public func setActive(_ active: Bool) {
    self.active = active
    model.setActive(active)
    if active { sync() } else { requestID = nil }
  }

  public func sync() {
    guard active, let session, session.activationState == .activated else { return }
    phoneReachable = session.isReachable
    companionInstalled = session.isCompanionAppInstalled
    guard session.isReachable else { return }
    let id = UUID()
    requestID = id
    guard let data = try? JSONEncoder().encode(CompanionSyncRequest(requestID: id)) else { return }
    session.sendMessage([companionPayloadKey: data], replyHandler: { [weak self] message in
      guard let bytes = companionBytes(message), let reply = try? JSONDecoder().decode(CompanionSyncReply.self, from: bytes) else { return }
      Task { @MainActor in
        guard let self, self.active, self.requestID == reply.requestID else { return }
        self.requestID = nil
        await self.model.receive(reply.snapshot, authoritative: true)
        await self.model.refresh()
      }
    }, errorHandler: { [weak self] _ in
      Task { @MainActor in
        guard let self, self.requestID == id else { return }
        self.requestID = nil
        self.phoneReachable = false
      }
    })
  }

  public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    let context = session.receivedApplicationContext
    receive(context)
    Task { @MainActor in self.sync() }
  }

  public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      self.phoneReachable = session.isReachable
      if session.isReachable { self.sync() }
    }
  }

  public nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { receive(applicationContext) }

  private nonisolated func receive(_ context: [String: Any]) {
    guard let bytes = companionBytes(context), let snapshot = try? JSONDecoder().decode(CompanionSnapshot.self, from: bytes) else { return }
    Task { @MainActor in
      await self.model.receive(snapshot, authoritative: false)
      self.sync()
    }
  }
}
#endif
