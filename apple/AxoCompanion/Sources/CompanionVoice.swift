import Foundation

/// Only identity fingerprints cross with audio metadata; a recording never carries a login token.
public struct CompanionVoiceRequest: Codable, Equatable, Sendable {
  public static let maximumAudioBytes = 1_048_576
  public static let maximumDuration: TimeInterval = 90
  public let id: UUID
  public let accountID: UUID
  public let signInFingerprint: String
  public let expiresAt: Date

  public init(session: CompanionSession, now: Date = .now) {
    id = UUID()
    accountID = session.accountID
    signInFingerprint = CompanionAuthentication.signedIn(session).fingerprint
    expiresAt = now.addingTimeInterval(300)
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    id = try fields.decode(UUID.self, forKey: .id)
    accountID = try fields.decode(UUID.self, forKey: .accountID)
    signInFingerprint = try fields.decode(String.self, forKey: .signInFingerprint)
    expiresAt = try fields.decode(Date.self, forKey: .expiresAt)
    guard signInFingerprint.count == 64, signInFingerprint.allSatisfy({ $0.isASCII && ($0.isHexDigit && !$0.isUppercase) }) else {
      throw CompanionError.invalidMessage
    }
  }

  func isFresh(now: Date = .now) -> Bool { expiresAt > now && expiresAt.timeIntervalSince(now) <= 310 }

  public func isAuthorized(by authentication: CompanionAuthentication, now: Date = .now) -> Bool {
    guard let session = authentication.session, session.accountID == accountID,
      isFresh(now: now) else { return false }
    return signInFingerprint == authentication.fingerprint
  }
}

/// A short recording fits WatchConnectivity's immediate message budget, avoiding the system's
/// background file-transfer scheduling. Longer recordings use the bounded file path instead.
struct CompanionVoiceAudioPacket: Codable, Sendable {
  static let maximumBytes = 40_000
  let request: CompanionVoiceRequest
  let audio: Data

  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 60_000 else { throw CompanionVoiceFailure.invalidAudio }
    let packet = try JSONDecoder().decode(Self.self, from: data)
    guard !packet.audio.isEmpty, packet.audio.count <= maximumBytes, packet.request.isFresh() else {
      throw CompanionVoiceFailure.invalidAudio
    }
    return packet
  }
}

public enum CompanionVoiceFailure: String, Codable, Error, LocalizedError, Sendable {
  case phoneUnavailable, unsupported, noSpeech, invalidAudio, expired, failed

  public var errorDescription: String? {
    switch self {
    case .phoneUnavailable: "Open Axo on your iPhone and try again. Nothing was sent."
    case .unsupported: "Watch voice needs on-device speech on an iPhone running iOS 26 or later."
    case .noSpeech: "Nothing was heard. Try speaking closer to your Watch."
    case .invalidAudio: "The recording could not be read. Nothing was sent."
    case .expired: "Voice transfer timed out. Nothing was sent. Try again with your iPhone nearby."
    case .failed: "Your iPhone could not transcribe the recording. Open Axo there and try again."
    }
  }
}

public struct CompanionVoiceReply: Codable, Sendable {
  public enum Outcome: Codable, Sendable { case transcript(String), failure(CompanionVoiceFailure) }
  public let request: CompanionVoiceRequest
  public let outcome: Outcome

  public init(request: CompanionVoiceRequest, outcome: Outcome) {
    self.request = request
    self.outcome = outcome
  }

  public func transcript(for pending: CompanionVoiceRequest, authentication: CompanionAuthentication, now: Date = .now) throws -> String {
    guard request == pending, request.isAuthorized(by: authentication, now: now) else { throw CompanionVoiceFailure.expired }
    switch outcome {
    case .failure(let error): throw error
    case .transcript(let text):
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw CompanionVoiceFailure.noSpeech }
      guard text.utf8.count <= 32_768 else { throw CompanionVoiceFailure.failed }
      return text
    }
  }
}

#if os(iOS) || os(watchOS)
let companionVoiceRequestKey = "axo.voice.request.v1"
let companionVoiceReplyKey = "axo.voice.reply.v1"
let companionVoiceCancelKey = "axo.voice.cancel.v1"
#endif
