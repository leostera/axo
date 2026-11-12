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
  private struct PendingVoice {
    let request: CompanionVoiceRequest
    var transfer: WCSessionFileTransfer?
    let result: CheckedContinuation<String, Error>
    let timeout: Task<Void, Never>
  }
  private var pendingVoice: PendingVoice?

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

  /// Audio leaves the Watch only after the person taps Send. Its response remains bound to
  /// this sign-in and request, and can be cancelled before any agent prompt is sent.
  public func transcribeAudio(_ file: URL) async throws -> String {
    guard let session, session.activationState == .activated, session.isCompanionAppInstalled,
      pendingVoice == nil, let login = model.login.session else { throw CompanionVoiceFailure.phoneUnavailable }
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0,
      size <= CompanionVoiceRequest.maximumAudioBytes else { throw CompanionVoiceFailure.invalidAudio }
    let request = CompanionVoiceRequest(session: login)
    let metadata = [companionVoiceRequestKey: try JSONEncoder().encode(request)]
    let packet: Data?
    if session.isReachable, size <= CompanionVoiceAudioPacket.maximumBytes {
      packet = try JSONEncoder().encode(CompanionVoiceAudioPacket(request: request, audio: Data(contentsOf: file)))
    } else { packet = nil }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { result in
        let timeout = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(150)) } catch { return }
          self?.finishVoice(request.id, result: .failure(CompanionVoiceFailure.expired), cancel: true)
        }
        pendingVoice = PendingVoice(request: request, transfer: nil, result: result, timeout: timeout)
        if let packet {
          session.sendMessageData(packet, replyHandler: { _ in }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.transferVoiceFile(request.id, file: file, metadata: metadata) }
          })
        } else { transferVoiceFile(request.id, file: file, metadata: metadata) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finishVoice(request.id, result: .failure(CancellationError()), cancel: true)
      }
    }
  }

  private func transferVoiceFile(_ id: UUID, file: URL, metadata: [String: Data]) {
    guard let session, pendingVoice?.request.id == id, pendingVoice?.transfer == nil else { return }
    pendingVoice?.transfer = session.transferFile(file, metadata: metadata)
  }

  private func finishVoice(_ id: UUID, result: Result<String, Error>, cancel: Bool) {
    guard let pendingVoice, pendingVoice.request.id == id else { return }
    self.pendingVoice = nil
    pendingVoice.timeout.cancel()
    if cancel {
      pendingVoice.transfer?.cancel()
      if let session {
        let message = [companionVoiceCancelKey: id.uuidString]
        session.transferUserInfo(message)
        if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
      }
    }
    pendingVoice.result.resume(with: result)
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
  public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { receiveVoiceReply(userInfo) }
  public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) { receiveVoiceReply(message) }

  public nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    guard error != nil, let bytes = fileTransfer.file.metadata?[companionVoiceRequestKey] as? Data,
      let request = try? JSONDecoder().decode(CompanionVoiceRequest.self, from: bytes) else { return }
    Task { @MainActor in
      self.finishVoice(request.id, result: .failure(CompanionVoiceFailure.phoneUnavailable), cancel: true)
    }
  }

  private nonisolated func receiveVoiceReply(_ message: [String: Any]) {
    guard let bytes = message[companionVoiceReplyKey] as? Data, bytes.count <= 60_000,
      let reply = try? JSONDecoder().decode(CompanionVoiceReply.self, from: bytes) else { return }
    Task { @MainActor in
      guard let pending = self.pendingVoice, reply.request.id == pending.request.id else { return }
      do {
        let authentication = self.model.login.snapshot?.authentication ?? .signedOut
        let text = try reply.transcript(for: pending.request, authentication: authentication)
        self.finishVoice(pending.request.id, result: .success(text), cancel: false)
      } catch {
        self.finishVoice(pending.request.id, result: .failure(error), cancel: true)
      }
    }
  }

  private nonisolated func receive(_ context: [String: Any]) {
    guard let bytes = companionBytes(context), let snapshot = try? JSONDecoder().decode(CompanionSnapshot.self, from: bytes) else { return }
    Task { @MainActor in
      await self.model.receive(snapshot, authoritative: false)
      self.sync()
    }
  }
}
#endif
