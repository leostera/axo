#if os(iOS)
import Foundation
import Security
import WatchConnectivity

@MainActor
final class PhoneVoiceTranscription {
  private let authentication: @MainActor () async throws -> CompanionAuthentication
  private let transcribe: @Sendable (URL) async throws -> String
  private let publisher = CompanionSnapshotPublisher()
  private var active: (request: CompanionVoiceRequest, task: Task<Void, Never>)?
  private var replies: [UUID: CompanionVoiceReply] = [:]
  private var cancelled: [UUID: Date] = [:]

  init(authentication: @escaping @MainActor () async throws -> CompanionAuthentication,
    transcribe: @escaping @Sendable (URL) async throws -> String
  ) {
    self.authentication = authentication
    self.transcribe = transcribe
  }

  func authenticationChanged(_ authentication: CompanionAuthentication) {
    if let active, !active.request.isAuthorized(by: authentication) { active.task.cancel() }
    if authentication.session == nil { replies = [:] }
  }

  /// WCSession removes the incoming temporary file after its delegate returns. Copy and bound
  /// it synchronously, before handing analysis to an async task. The path is never caller-chosen.
  nonisolated static func receiveFile(_ file: WCSessionFile) -> (CompanionVoiceRequest, URL)? {
    guard let bytes = file.metadata?[companionVoiceRequestKey] as? Data, bytes.count <= 2048,
      let request = try? JSONDecoder().decode(CompanionVoiceRequest.self, from: bytes), request.expiresAt > Date(),
      let values = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true, let size = values.fileSize, size > 0, size <= CompanionVoiceRequest.maximumAudioBytes
    else { return nil }
    var copied: URL?
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axo-watch-voice", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let copy = directory.appendingPathComponent(UUID().uuidString + ".m4a")
      copied = copy
      try FileManager.default.copyItem(at: file.fileURL, to: copy)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copy.path)
      return (request, copy)
    } catch {
      if let copied { try? FileManager.default.removeItem(at: copied) }
      return nil
    }
  }

  nonisolated static func receivePacket(_ data: Data) -> (CompanionVoiceRequest, URL)? {
    var copy: URL?
    do {
      let packet = try CompanionVoiceAudioPacket.decode(data)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axo-watch-voice", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent(UUID().uuidString + ".m4a")
      copy = file
      try packet.audio.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
      return (packet.request, file)
    } catch {
      if let copy { try? FileManager.default.removeItem(at: copy) }
      return nil
    }
  }

  func cancel(_ id: UUID) {
    cancelled = cancelled.filter { $0.value > Date() }
    if cancelled.count >= 64, let oldest = cancelled.min(by: { $0.value < $1.value })?.key { cancelled[oldest] = nil }
    cancelled[id] = Date().addingTimeInterval(300)
    if active?.request.id == id { active?.task.cancel() }
    replies[id] = nil
  }

  func receive(_ request: CompanionVoiceRequest, audio: URL, session: WCSession) {
    if let until = cancelled[request.id], until > Date() {
      try? FileManager.default.removeItem(at: audio)
      return
    }
    replies = replies.filter { $0.value.request.expiresAt > Date() }
    if let reply = replies[request.id], reply.request == request {
      try? FileManager.default.removeItem(at: audio)
      deliver(reply, session: session)
      return
    }
    guard active == nil else {
      try? FileManager.default.removeItem(at: audio)
      if active?.request.id != request.id { deliver(.init(request: request, outcome: .failure(.phoneUnavailable)), session: session) }
      return
    }
    let task = Task { [self] in
      defer {
        try? FileManager.default.removeItem(at: audio)
        if active?.request.id == request.id { active = nil }
      }
      let reply: CompanionVoiceReply
      do {
        guard try await isAuthorized(request) else { throw CompanionVoiceFailure.phoneUnavailable }
        try Task.checkCancellation()
        let text = try await transcribe(audio)
        try Task.checkCancellation()
        guard try await isAuthorized(request) else { throw CompanionVoiceFailure.phoneUnavailable }
        reply = CompanionVoiceReply(request: request, outcome: .transcript(text))
      } catch let failure as CompanionVoiceFailure {
        reply = CompanionVoiceReply(request: request, outcome: .failure(failure))
      } catch {
        reply = CompanionVoiceReply(request: request, outcome: .failure(.failed))
      }
      guard !Task.isCancelled else { return }
      // Keep only a few short-lived replies so duplicate file deliveries do not rerun speech.
      if replies.count >= 8, let oldest = replies.min(by: { $0.value.request.expiresAt < $1.value.request.expiresAt })?.key { replies[oldest] = nil }
      replies[request.id] = reply
      deliver(reply, session: session)
    }
    active = (request, task)
  }

  private func isAuthorized(_ request: CompanionVoiceRequest) async throws -> Bool {
    do {
      let current = try await authentication()
      authenticationChanged(current)
      return request.isAuthorized(by: current)
    } catch CompanionError.storage(let status) where status == errSecInteractionNotAllowed {
      // Transcribing locally does not need a bearer token. The last published, non-secret
      // identity recognizes the Watch while locked; its HTTPS prompt still needs real auth.
      return publisher.matchesPublishedVoiceIdentity(request)
    }
  }

  private func deliver(_ reply: CompanionVoiceReply, session: WCSession) {
    guard let data = try? JSONEncoder().encode(reply), data.count <= 60_000 else { return }
    let message = [companionVoiceReplyKey: data]
    session.transferUserInfo(message)
    if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: nil) }
  }
}
#endif
