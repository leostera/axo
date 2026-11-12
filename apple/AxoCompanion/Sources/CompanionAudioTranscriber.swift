#if (os(iOS) || os(macOS)) && canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// File transcription uses the same on-device SpeechTranscriber as the phone's live voice UI.
/// Recordings are never uploaded to Axo or to a third-party speech API.
@available(iOS 26, macOS 26, *)
public actor CompanionAudioTranscriber {
  public init() {}

  public func transcribe(_ url: URL) async throws -> String {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let bytes = values.fileSize,
      bytes > 0, bytes <= CompanionVoiceRequest.maximumAudioBytes else { throw CompanionVoiceFailure.invalidAudio }
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard rate > 0, Double(file.length) / rate <= CompanionVoiceRequest.maximumDuration + 2 else {
      throw CompanionVoiceFailure.invalidAudio
    }
    guard SpeechTranscriber.isAvailable else { throw CompanionVoiceFailure.unsupported }
    var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
    guard let locale else { throw CompanionVoiceFailure.unsupported }
    _ = try await AssetInventory.reserve(locale: locale)
    let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
      try await withTaskCancellationHandler {
        try await installation.downloadAndInstall()
      } onCancel: { installation.progress.cancel() }
    }
    try Task.checkCancellation()
    let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    let results = Task {
      var text = ""
      for try await result in module.results where result.isFinal {
        text += String(result.text.characters)
      }
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    do {
      return try await withTaskCancellationHandler {
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await results.value
        guard !text.isEmpty else { throw CompanionVoiceFailure.noSpeech }
        guard text.utf8.count <= 32_768 else { throw CompanionVoiceFailure.failed }
        return text
      } onCancel: {
        results.cancel()
        Task { await analyzer.cancelAndFinishNow() }
      }
    } catch {
      results.cancel()
      await analyzer.cancelAndFinishNow()
      throw error
    }
  }
}
#endif
