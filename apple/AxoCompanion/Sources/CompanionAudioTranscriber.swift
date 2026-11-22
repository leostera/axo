#if os(iOS) || os(macOS)
import AVFoundation
import Foundation

/// Watch recordings traverse only the existing paired-device transport. The phone decodes them
/// with the same local English model as live dictation.
public struct CompanionAudioTranscriber: Sendable {
  private let speech: ParakeetSpeech

  public init() { self.init(speech: .shared) }

  init(speech: ParakeetSpeech) { self.speech = speech }

  public func transcribe(_ url: URL) async throws -> String {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let bytes = values.fileSize,
        bytes > 0, bytes <= CompanionVoiceRequest.maximumAudioBytes else { throw CompanionVoiceFailure.invalidAudio }
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      guard format.sampleRate > 0, format.sampleRate <= 192_000, (1...2).contains(format.channelCount),
        file.length > 0, Double(file.length) / format.sampleRate <= CompanionVoiceRequest.maximumDuration + 2
      else { throw CompanionVoiceFailure.invalidAudio }
    } catch { throw CompanionVoiceFailure.invalidAudio }

    let id = UUID()
    do {
      // A first-time model download is too large for a Watch request/background wake.
      // Report setup-needed rather than gambling with Send or silently choosing another engine.
      try await speech.prepare(for: id, allowDownload: false)
      let text = try await speech.transcribeFile(url, for: id)
      try Task.checkCancellation()
      guard !text.isEmpty else { throw CompanionVoiceFailure.noSpeech }
      guard text.utf8.count <= 32_768 else { throw CompanionVoiceFailure.failed }
      await speech.release(id)
      return text
    } catch {
      await speech.release(id)
      if error as? ParakeetError == .modelNotReady { throw CompanionVoiceFailure.modelNotReady }
      throw error
    }
  }
}
#endif
