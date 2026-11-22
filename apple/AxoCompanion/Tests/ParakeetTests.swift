#if os(macOS)
import AVFoundation
import Foundation
import XCTest
@testable import AxoCompanion

final class ParakeetTests: XCTestCase {
  func testMissingModelFailsWithoutDownloadAndRetiresStaging() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = root.appendingPathComponent("staging")
    let revision = root.appendingPathComponent(ParakeetAssets.revision)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
    let speech = ParakeetSpeech(cacheRoot: root)

    for _ in 0..<2 {
      do {
        try await speech.prepare(for: UUID(), allowDownload: false)
        XCTFail("An incomplete cache must never be used")
      } catch { XCTAssertEqual(error as? ParakeetError, .modelNotReady) }
    }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  func testAssetVerificationRejectsSameSizeCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = ParakeetAssets.File("sample", 3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let url = root.appendingPathComponent(file.path)
    try Data("abc".utf8).write(to: url)
    XCTAssertTrue(try file.verify(in: root))
    try Data("xyz".utf8).write(to: url)
    XCTAssertFalse(try file.verify(in: root))
  }

  func testRealParakeetOnPCMAndWatchAACWhenRequested() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let fixture = env["AXO_PARAKEET_FIXTURE"], let cache = env["AXO_PARAKEET_TEST_CACHE"] else {
      throw XCTSkip("Opt in with a synthetic 16 kHz mono WAV and sibling .m4a; ordinary tests do not download models")
    }
    let pcm = URL(fileURLWithPath: fixture)
    let aac = pcm.deletingPathExtension().appendingPathExtension("m4a")
    let speech = ParakeetSpeech(cacheRoot: URL(fileURLWithPath: cache))
    let id = UUID()
    try await speech.prepare(for: id, allowDownload: true)
    do {
      try await speech.prepare(for: UUID(), allowDownload: false)
      XCTFail("A second recording must not load another recognizer")
    } catch { XCTAssertEqual(error as? ParakeetError, .busy) }
    let pcmFile = try AVAudioFile(forReading: pcm)
    XCTAssertEqual(pcmFile.processingFormat.sampleRate, 16_000)
    XCTAssertEqual(pcmFile.processingFormat.channelCount, 1)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: pcmFile.processingFormat,
      frameCapacity: AVAudioFrameCount(pcmFile.length)))
    try pcmFile.read(into: buffer)
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    let text = try await speech.transcribe(samples, for: id)
    await speech.release(id)
    let watchText = try await CompanionAudioTranscriber(speech: speech).transcribe(aac)
    for (input, transcript) in [("PCM", text), ("Watch AAC", watchText)] {
      print("Parakeet v2 synthetic fixture [\(input)]: \(transcript)")
      // Punctuation can legitimately differ across inputs and Core ML compute units.
      let words = transcript.lowercased().split { !$0.isLetter }.map(String.init)
      XCTAssertEqual(words, "hello world the little bird is singing in the garden".components(separatedBy: " "))
    }
  }
}
#endif
