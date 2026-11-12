import Foundation
import XCTest
@testable import AxoCompanion

final class CompanionVoiceTests: XCTestCase {
  private func session(account: UUID = UUID(uuidString: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11")!, seed: UInt8 = 0) throws -> CompanionSession {
    let secret = Data(repeating: seed, count: 32).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return try CompanionSession(token: "axo1.\(account.uuidString.lowercased()).\(secret)")
  }

  func testAudioMetadataContainsNoBearerTokenAndIsBoundToOneSignIn() throws {
    let login = try session()
    let now = Date()
    let request = CompanionVoiceRequest(session: login, now: now)
    let data = try JSONEncoder().encode(request)
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(login.token))
    let parsed = try JSONDecoder().decode(CompanionVoiceRequest.self, from: data)
    XCTAssertEqual(parsed, request)
    XCTAssertTrue(parsed.isAuthorized(by: .signedIn(login), now: now))
    XCTAssertFalse(parsed.isAuthorized(by: .signedOut, now: now))
    XCTAssertFalse(parsed.isAuthorized(by: .signedIn(try session(seed: 1)), now: now), "same account, different sign-in")
    XCTAssertFalse(parsed.isAuthorized(by: .signedIn(try session(account: UUID())), now: now))
    XCTAssertFalse(parsed.isAuthorized(by: .signedIn(login), now: now.addingTimeInterval(301)))
  }

  @MainActor func testLockedPhoneMetadataRecognizesOnlyThePublishedSignInAndSignOutRevokesIt() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "voice-identity-tests-\(UUID())"))
    let publisher = CompanionSnapshotPublisher(defaults: defaults)
    let login = try session()
    let request = CompanionVoiceRequest(session: login)
    XCTAssertFalse(publisher.matchesPublishedVoiceIdentity(request))
    _ = try publisher.snapshot(for: .signedIn(login))
    XCTAssertTrue(publisher.matchesPublishedVoiceIdentity(request))
    XCTAssertFalse(publisher.matchesPublishedVoiceIdentity(CompanionVoiceRequest(session: try session(seed: 1))))
    _ = try publisher.snapshot(for: .signedOut)
    XCTAssertFalse(publisher.matchesPublishedVoiceIdentity(request))
  }

  func testLateOrWrongRequestCannotProduceTextForANewRecording() throws {
    let login = try session()
    let request = CompanionVoiceRequest(session: login)
    let reply = CompanionVoiceReply(request: request, outcome: .transcript(" hello from my wrist "))
    XCTAssertEqual(try reply.transcript(for: request, authentication: .signedIn(login)), "hello from my wrist")
    XCTAssertThrowsError(try reply.transcript(for: CompanionVoiceRequest(session: login), authentication: .signedIn(login)))
    XCTAssertThrowsError(try reply.transcript(for: request, authentication: .signedOut))
    XCTAssertThrowsError(try reply.transcript(for: request, authentication: .signedIn(login), now: Date().addingTimeInterval(301)))
  }

  func testNoSpeechAndOversizedRepliesFailWithoutSendingAnything() throws {
    let login = try session()
    let request = CompanionVoiceRequest(session: login)
    for text in ["  \n ", String(repeating: "x", count: 32_769)] {
      let reply = CompanionVoiceReply(request: request, outcome: .transcript(text))
      XCTAssertThrowsError(try reply.transcript(for: request, authentication: .signedIn(login)))
    }
    let failed = CompanionVoiceReply(request: request, outcome: .failure(.phoneUnavailable))
    XCTAssertThrowsError(try failed.transcript(for: request, authentication: .signedIn(login))) { error in
      XCTAssertEqual(error as? CompanionVoiceFailure, .phoneUnavailable)
    }
  }

  func testImmediateAudioPacketHasAHardBudgetAndPreservesTheRequest() throws {
    let request = CompanionVoiceRequest(session: try session())
    let packet = CompanionVoiceAudioPacket(request: request, audio: Data(repeating: 7, count: CompanionVoiceAudioPacket.maximumBytes))
    let encoded = try JSONEncoder().encode(packet)
    XCTAssertLessThan(encoded.count, 60_000)
    let decoded = try CompanionVoiceAudioPacket.decode(encoded)
    XCTAssertEqual(decoded.request, request)
    XCTAssertEqual(decoded.audio, packet.audio)
    for size in [0, CompanionVoiceAudioPacket.maximumBytes + 1] {
      let invalid = CompanionVoiceAudioPacket(request: request, audio: Data(repeating: 0, count: size))
      XCTAssertThrowsError(try CompanionVoiceAudioPacket.decode(JSONEncoder().encode(invalid)))
    }
    XCTAssertThrowsError(try CompanionVoiceAudioPacket.decode(Data(repeating: 0, count: 60_001)))
  }

  func testAudioReplyRoundTripPreservesRequestBinding() throws {
    let login = try session()
    let request = CompanionVoiceRequest(session: login)
    let reply = CompanionVoiceReply(request: request, outcome: .transcript("hello world"))
    let parsed = try JSONDecoder().decode(CompanionVoiceReply.self, from: JSONEncoder().encode(reply))
    XCTAssertEqual(try parsed.transcript(for: request, authentication: .signedIn(login)), "hello world")
  }

  func testRealSpeechFixtureWhenRequested() async throws {
    #if os(macOS)
    guard #available(macOS 26, *) else { throw XCTSkip("Requires SpeechAnalyzer") }
    guard let path = ProcessInfo.processInfo.environment["AXO_REAL_SPEECH_FIXTURE"] else {
      throw XCTSkip("Opt in with a synthetic speech fixture; ordinary unit tests never download speech models")
    }
    let text = try await CompanionAudioTranscriber().transcribe(URL(fileURLWithPath: path))
    let words = text.lowercased().split { !$0.isLetter }.map(String.init)
    XCTAssertTrue(words.contains("hello"), "Synthetic hello-world fixture should be recognized")
    XCTAssertTrue(words.contains("world"), "Synthetic hello-world fixture should be recognized")
    #endif
  }

  func testOversizedAudioIsRejectedBeforeAnySpeechModelPreparation() async throws {
    #if os(macOS)
    guard #available(macOS 26, *) else { throw XCTSkip("Requires SpeechAnalyzer") }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("oversize-voice-\(UUID()).m4a")
    try Data(repeating: 0, count: CompanionVoiceRequest.maximumAudioBytes + 1).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    do { _ = try await CompanionAudioTranscriber().transcribe(file); XCTFail("Oversized audio must be refused") }
    catch { XCTAssertEqual(error as? CompanionVoiceFailure, .invalidAudio) }
    #endif
  }
}
