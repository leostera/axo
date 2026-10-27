import Foundation
import XCTest

@testable import AxoPhoneModel

@MainActor
final class VoicePromptTests: XCTestCase {
  func testOneTapAsksSetsUpAndListensAndTheModelIsSetUpOnlyOnce() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    XCTAssertEqual(engine.preparations, 1)
    XCTAssertEqual(engine.starts, 1)
    engine.say(HeardText(settled: "Hello", tentative: ""))
    voice.finish(.draft)
    try await until { voice.state == .idle }
    voice.start()
    try await until { voice.isListening }
    XCTAssertEqual(engine.preparations, 1, "A model already set up is not set up again")
    XCTAssertEqual(engine.starts, 2)
  }

  func testWordsShowAsTheyAreHeard() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    engine.say(HeardText(settled: "Fix the", tentative: " bug"))
    XCTAssertEqual(voice.state, .listening(HeardText(settled: "Fix the", tentative: " bug")))
  }

  func testStopPutsTheWordsInTheBoxAndOnlySendSends() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    engine.finalText = "  Fix the bug.  "
    voice.finish(.draft)
    try await until { voice.transcript != nil }
    XCTAssertEqual(voice.transcript?.text, "Fix the bug.")
    XCTAssertEqual(voice.transcript?.delivery, .draft)
    XCTAssertEqual(voice.state, .idle)

    voice.start()
    XCTAssertNil(voice.transcript, "A new dictation drops the last one's words")
    try await until { voice.isListening }
    voice.finish(.send)
    try await until { voice.transcript != nil }
    XCTAssertEqual(voice.transcript?.delivery, .send)
  }

  func testTheTranscriptIsHandedOverOnce() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    voice.finish(.draft)
    try await until { voice.transcript != nil }
    let transcript = try XCTUnwrap(voice.transcript)
    voice.consume(VoiceTranscript(text: "someone else's", delivery: .draft))
    XCTAssertEqual(voice.transcript, transcript)
    voice.consume(transcript)
    XCTAssertNil(voice.transcript)
  }

  func testNoMicrophoneMeansNoSetupAndNoListening() async throws {
    let engine = FakeDictation()
    engine.permission = false
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { if case .failed = voice.state { true } else { false } }
    XCTAssertEqual(voice.state, .failed(VoicePromptError.microphoneDenied.localizedDescription))
    XCTAssertEqual(engine.preparations, 0)
    XCTAssertEqual(engine.starts, 0)
    voice.dismissFailure()
    XCTAssertEqual(voice.state, .idle)
  }

  func testCancellingSetupNeverStartsListeningLater() async throws {
    let engine = FakeDictation()
    engine.holdPreparation = true
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { if case .preparing = voice.state { true } else { false } }
    engine.report(VoiceSetupProgress(stage: .downloading, fraction: 0.4))
    XCTAssertEqual(voice.state, .preparing(VoiceSetupProgress(stage: .downloading, fraction: 0.4)))
    voice.cancel()
    XCTAssertEqual(voice.state, .idle)
    engine.report(VoiceSetupProgress(stage: .downloading, fraction: 0.6))
    XCTAssertEqual(voice.state, .idle, "a cancelled setup's progress does not bring it back")
    engine.releasePreparation()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(voice.state, .idle)
    XCTAssertEqual(engine.starts, 0)
  }

  func testCancelForgetsWhatWasHeardAndLateWordsDoNotComeBack() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    engine.say(HeardText(settled: "secret", tentative: ""))
    voice.cancel()
    XCTAssertEqual(voice.state, .idle)
    XCTAssertNil(voice.transcript)
    engine.say(HeardText(settled: "secret later", tentative: ""))
    XCTAssertEqual(voice.state, .idle)
    try await until { engine.cancels >= 1 }
  }

  func testCancelWhileFinishingDropsTheWords() async throws {
    let engine = FakeDictation()
    engine.holdFinish = true
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    voice.finish(.send)
    XCTAssertEqual(voice.state, .finishing)
    try await until { engine.isHoldingFinish }
    voice.cancel()
    engine.releaseFinish()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(voice.transcript, "A cancelled dictation is never sent")
    XCTAssertEqual(voice.state, .idle)
  }

  func testSilenceIsAFailureNotAnEmptyMessage() async throws {
    let engine = FakeDictation()
    engine.finalText = "   "
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    voice.finish(.send)
    try await until { if case .failed = voice.state { true } else { false } }
    XCTAssertNil(voice.transcript)
  }

  func testAnInterruptionEndsListeningWithoutWords() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { voice.isListening }
    engine.interrupt()
    XCTAssertEqual(voice.state, .failed(VoicePromptError.interrupted.localizedDescription))
    XCTAssertNil(voice.transcript)
  }

  func testAFailedSetupCanBeTriedAgain() async throws {
    let engine = FakeDictation()
    engine.prepareError = FakeError()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { if case .failed = voice.state { true } else { false } }
    XCTAssertEqual(engine.starts, 0)
    engine.prepareError = nil
    voice.start()
    try await until { voice.isListening }
    XCTAssertEqual(engine.preparations, 2)
  }

  func testTappingAgainWhileBusyDoesNothing() async throws {
    let engine = FakeDictation()
    let voice = VoicePrompt(engine: engine)
    voice.start()
    voice.start()
    try await until { voice.isListening }
    voice.start()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(engine.starts, 1)
    XCTAssertTrue(voice.isListening)
  }

  func testCancellingWhileAskingForTheMicrophoneNeverListens() async throws {
    let engine = FakeDictation()
    engine.holdPermission = true
    let voice = VoicePrompt(engine: engine)
    voice.start()
    try await until { engine.isHoldingPermission }
    voice.cancel()
    engine.releasePermission()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(voice.state, .idle)
    XCTAssertEqual(engine.preparations, 0)
    XCTAssertEqual(engine.starts, 0)
  }

  func testDictationGoesAfterWhatIsTyped() {
    let transcript = VoiceTranscript(text: "and the tests", delivery: .draft)
    XCTAssertEqual(transcript.appending(to: ""), "and the tests")
    XCTAssertEqual(transcript.appending(to: "Fix the bug"), "Fix the bug and the tests")
    XCTAssertEqual(transcript.appending(to: "Fix the bug\n"), "Fix the bug\nand the tests")
  }

  func testTheWaveformShowsSpeechAndNotSilence() {
    XCTAssertEqual(VoiceWaveformScale.heightFraction(for: 0), 0)
    XCTAssertEqual(VoiceWaveformScale.heightFraction(for: .nan), 0)
    XCTAssertEqual(VoiceWaveformScale.heightFraction(for: 0.001), 0, accuracy: 0.0001)
    XCTAssertEqual(VoiceWaveformScale.heightFraction(for: 1), 1)
    XCTAssertEqual(VoiceWaveformScale.heightFraction(for: 0.2), 1)
    let quiet = VoiceWaveformScale.heightFraction(for: 0.01)
    XCTAssertGreaterThan(quiet, 0.2)
    XCTAssertLessThan(quiet, 0.8)
  }

  private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out", file: file, line: line)
    throw FakeError()
  }
}

private struct FakeError: LocalizedError { var errorDescription: String? { "fake failure" } }

@MainActor
private final class FakeDictation: DictationEngine {
  var audioLevel: Double = 0.5
  var permission = true
  var prepareError: Error?
  var holdPreparation = false
  var holdFinish = false
  var holdPermission = false
  var finalText = "Hello"
  private(set) var preparations = 0
  private(set) var starts = 0
  private(set) var cancels = 0
  private var heard: (@MainActor (HeardText) -> Void)?
  private var interrupted: (@MainActor () -> Void)?
  private var progress: (@MainActor (VoiceSetupProgress) -> Void)?
  private var preparationGate: CheckedContinuation<Void, Never>?
  private var finishGate: CheckedContinuation<Void, Never>?
  private var permissionGate: CheckedContinuation<Void, Never>?
  var isHoldingFinish: Bool { finishGate != nil }
  var isHoldingPermission: Bool { permissionGate != nil }

  func requestPermission() async -> Bool {
    if holdPermission { await withCheckedContinuation { permissionGate = $0 } }
    return permission
  }

  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws {
    preparations += 1
    self.progress = progress
    if holdPreparation { await withCheckedContinuation { preparationGate = $0 } }
    if let prepareError { throw prepareError }
  }

  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws {
    starts += 1
    self.heard = heard
    self.interrupted = interrupted
  }

  func finish() async throws -> String {
    if holdFinish { await withCheckedContinuation { finishGate = $0 } }
    return finalText
  }

  func cancel() async { cancels += 1 }

  func say(_ text: HeardText) { heard?(text) }
  func report(_ value: VoiceSetupProgress) { progress?(value) }
  func interrupt() { interrupted?() }
  func releasePreparation() { preparationGate?.resume(); preparationGate = nil }
  func releasePermission() { permissionGate?.resume(); permissionGate = nil }
  func releaseFinish() { finishGate?.resume(); finishGate = nil }
}
