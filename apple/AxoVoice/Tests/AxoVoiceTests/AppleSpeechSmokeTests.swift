import Foundation
import Speech
import XCTest
@testable import AxoVoice

final class AppleSpeechSmokeTests: XCTestCase {
    func testAppleModelOnSyntheticSpeech() async throws {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["AXO_APPLE_SPEECH_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in: uses Apple's local speech service and may install English language assets.")
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else {
            throw XCTSkip("Apple SpeechTranscriber is not available on this Mac.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-apple-speech-\(UUID()).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "Please list the files in the current directory."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)
        let engine = AppleSpeechTranscriber()
        try await engine.prepare { _ in }
        let text = try await engine.transcribe(url)
        XCTAssertTrue(text.lowercased().contains("list the files"), "Unexpected synthetic transcript: \(text)")
        // A finished analyzer is not reusable. The adapter must create a fresh one per clip.
        let repeated = try await engine.transcribe(url)
        XCTAssertEqual(repeated, text)
        await engine.unload()
        #else
        throw XCTSkip("Synthetic speech smoke test uses macOS say; microphone testing requires an iPhone.")
        #endif
    }
}
