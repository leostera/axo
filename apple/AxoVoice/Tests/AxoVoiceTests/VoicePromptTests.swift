import Foundation
import XCTest
@testable import AxoVoice

@MainActor
final class VoicePromptTests: XCTestCase {
    func testFirstApprovedTapPreparesAndStartsCaptureWithoutASecondTap() async throws {
        let recorder = FakeRecorder()
        let engine = FakeTranscriber()
        let voice = VoicePrompt(recorder: recorder, transcriber: engine)
        voice.prepareAndRecord()
        try await waitUntil { voice.state == .recording }
        XCTAssertEqual(recorder.starts, 1)
        voice.finishRecording()
        try await waitUntil { voice.state == .ready }
        voice.prepareAndRecord()
        try await waitUntil { voice.state == .recording }
        XCTAssertEqual(recorder.starts, 2)
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 1, "The loaded model must not be prepared again for the next tap")
        voice.cancel()
        try await waitUntil { voice.state == .idle }
    }

    func testCancellingPreparationNeverStartsCaptureLater() async throws {
        let recorder = FakeRecorder()
        let engine = FakeTranscriber()
        await engine.delayPreparation()
        let voice = VoicePrompt(recorder: recorder, transcriber: engine)
        voice.prepareAndRecord()
        try await waitUntil { if case .preparing = voice.state { true } else { false } }
        voice.cancel()
        try await waitUntil { voice.state == .idle }
        XCTAssertEqual(recorder.starts, 0)
    }

    func testPermissionDenialDoesNotDownloadOrRecord() async throws {
        let recorder = FakeRecorder()
        recorder.permission = false
        let engine = FakeTranscriber()
        let voice = VoicePrompt(recorder: recorder, transcriber: engine)
        voice.prepare()
        try await waitUntil { if case .failed = voice.state { true } else { false } }
        let downloads = await engine.preparations
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(recorder.starts, 0)
    }

    func testRecordingProducesTranscriptAndDeletesAudio() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        let audioURL = try XCTUnwrap(recorder.lastURL)
        voice.finishRecording()
        try await waitUntil { voice.state == .ready && voice.transcript != nil }
        XCTAssertEqual(voice.transcript?.text, "A dictated prompt.")
        XCTAssertEqual(voice.transcript?.appending(to: "My edited draft"), "My edited draft\nA dictated prompt.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let transcriptions = await engine.transcriptions
        XCTAssertEqual(transcriptions, 1)
    }

    func testCancelWhileRecordingDiscardsAudio() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        let audioURL = try XCTUnwrap(recorder.lastURL)
        voice.cancel()
        try await waitUntil { voice.state == .idle }
        XCTAssertNil(voice.transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let transcriptions = await engine.transcriptions
        XCTAssertEqual(transcriptions, 0)
    }

    func testCancellationRejectsLateTranscriptAndBlocksNewOperations() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        await engine.setBlocked(true)
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        let audioURL = try XCTUnwrap(recorder.lastURL)
        voice.finishRecording()
        try await waitForTranscription(engine)
        voice.cancel()
        voice.prepare()
        voice.startRecording()
        XCTAssertEqual(voice.state, .cancelling)
        // Simulate a Core ML call which completes despite cancellation.
        await engine.completeBlockedTranscription()
        try await waitUntil { voice.state == .idle }
        XCTAssertNil(voice.transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(recorder.starts, 1)
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 1)
    }

    func testInterruptionStopsMicrophoneAndDoesNotTranscribe() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        recorder.onInterrupted?()
        try await waitUntil { if case .failed = voice.state { true } else { false } }
        XCTAssertNil(recorder.ownedURL)
        XCTAssertNil(voice.transcript)
        let transcriptions = await engine.transcriptions
        XCTAssertEqual(transcriptions, 0)
    }

    func testRecorderCompletionTranscribesOnlyOnce() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        recorder.onFinished?()
        recorder.onFinished?()
        try await waitUntil { voice.state == .ready && voice.transcript != nil }
        let transcriptions = await engine.transcriptions
        XCTAssertEqual(transcriptions, 1)
    }

    func testEmptyTranscriptReportsFailureAndDeletesAudio() async throws {
        let (voice, recorder, engine) = try await preparedVoice()
        await engine.setResult("  \n")
        voice.startRecording()
        try await waitUntil { voice.state == .recording }
        let url = try XCTUnwrap(recorder.lastURL)
        voice.finishRecording()
        try await waitUntil { if case .failed = voice.state { true } else { false } }
        XCTAssertNil(voice.transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDraftAppendPreservesWhitespaceAndNeverTruncates() {
        let transcript = VoiceTranscript(text: "New words")
        XCTAssertEqual(transcript.appending(to: ""), "New words")
        XCTAssertEqual(transcript.appending(to: "Typed already. "), "Typed already. New words")
        let longDraft = String(repeating: "x", count: 16_000)
        XCTAssertEqual(transcript.appending(to: longDraft), longDraft + "\nNew words")
    }

    func testProgressIsFiniteAndBounded() {
        XCTAssertEqual(VoiceModelProgress(fraction: .nan, detail: "").fraction, 0)
        XCTAssertEqual(VoiceModelProgress(fraction: -1, detail: "").fraction, 0)
        XCTAssertEqual(VoiceModelProgress(fraction: 2, detail: "").fraction, 1)
    }

    private func preparedVoice() async throws -> (VoicePrompt, FakeRecorder, FakeTranscriber) {
        let recorder = FakeRecorder()
        let engine = FakeTranscriber()
        let voice = VoicePrompt(recorder: recorder, transcriber: engine)
        voice.prepare()
        try await waitUntil { voice.state == .ready }
        return (voice, recorder, engine)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Voice state did not settle")
        throw CancellationError()
    }

    private func waitForTranscription(_ engine: FakeTranscriber) async throws {
        for _ in 0..<200 {
            if await engine.isWaiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Transcription did not start")
        throw CancellationError()
    }
}

@MainActor
private final class FakeRecorder: VoiceRecording {
    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var permission = true
    var starts = 0
    var ownedURL: URL?
    var lastURL: URL?
    func requestPermission() async -> Bool { permission }
    func start() throws {
        starts += 1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-voice-test-\(UUID()).wav")
        try Data([0, 1, 2]).write(to: url)
        ownedURL = url
        lastURL = url
    }
    func stop() throws -> URL {
        guard let url = ownedURL else { throw VoicePromptError.recorderUnavailable }
        ownedURL = nil
        return url
    }
    func cancel() {
        if let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
        ownedURL = nil
    }
}

private actor FakeTranscriber: LocalSpeechTranscribing {
    var preparations = 0
    var transcriptions = 0
    var isWaiting: Bool { continuation != nil }
    private var result = " A dictated prompt. \n"
    private var blocked = false
    private var slowPreparation = false
    func delayPreparation() { slowPreparation = true }
    private var continuation: CheckedContinuation<String, Never>?
    func setBlocked(_ value: Bool) { blocked = value }
    func setResult(_ value: String) { result = value }
    func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws {
        preparations += 1
        if slowPreparation { try await Task.sleep(for: .seconds(1)) }
        progress(.init(fraction: 1, detail: "Ready"))
    }
    func transcribe(_ audioURL: URL) async throws -> String {
        transcriptions += 1
        if blocked { return await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func completeBlockedTranscription() { continuation?.resume(returning: result); continuation = nil }
    func unload() async {}
}
