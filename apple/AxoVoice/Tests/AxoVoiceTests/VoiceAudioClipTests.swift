import AVFoundation
import Foundation
import XCTest
@testable import AxoVoice

final class VoiceAudioClipTests: XCTestCase {
    func testSilentClipIsRejected() throws {
        let url = try makeClip(duration: 1, tone: false)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try VoiceAudioClip.open(url)) { error in
            guard case VoicePromptError.noSpeech = error else { return XCTFail("Expected no speech") }
        }
    }

    func testShortClipIsRejected() throws {
        let url = try makeClip(duration: 0.1, tone: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try VoiceAudioClip.open(url)) { error in
            guard case VoicePromptError.invalidClip = error else { return XCTFail("Expected invalid clip") }
        }
    }

    func testValidatedClipIsRewoundForTheSpeechAnalyzer() throws {
        let url = try makeClip(duration: 1, tone: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try VoiceAudioClip.open(url)
        XCTAssertEqual(file.framePosition, 0)
        XCTAssertEqual(file.length, 16_000)
    }

    func testMigrationDeletesOnlyTheOldModelCache() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("axo-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        let oldModels = support.appendingPathComponent("AxoVoice/Models")
        try FileManager.default.createDirectory(at: oldModels, withIntermediateDirectories: true)
        let otherData = support.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: otherData)
        try LegacyVoiceCleanup.removeParakeetCache(in: support)
        try LegacyVoiceCleanup.removeParakeetCache(in: support) // Idempotent.
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldModels.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherData.path))
    }

    private func makeClip(duration: Double, tone: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-clip-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let count = AVAudioFrameCount(duration * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0..<Int(count) { samples[index] = tone ? Float(sin(Double(index) * 0.1) * 0.2) : 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
