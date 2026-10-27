import AVFoundation
import AxoPhoneModel
import Foundation
import Speech
import os

/// Voice prompting is offered where Apple's on-device speech model is: iOS 26 and later.
@MainActor
enum Dictation {
  static func makeVoicePrompt() -> VoicePrompt? {
    #if DEBUG
    if PreviewFixture.requested { return VoicePrompt(engine: PreviewDictation()) }
    #endif
    guard #available(iOS 26, *) else { return nil }
    return VoicePrompt(engine: AppleDictation())
  }
}

enum AppleDictationError: LocalizedError {
  case unavailable, unsupportedLanguage, modelNotReady, noMicrophone
  /// Starting to listen failed at `step`; the system's own error says why.
  case couldNotStart(ListeningStep, any Error)

  var errorDescription: String? {
    switch self {
    case .unavailable: "On-device speech isn't available on this iPhone."
    case .unsupportedLanguage: "On-device speech doesn't support this iPhone's language yet."
    case .modelNotReady: "The speech model isn't ready. Connect to Wi-Fi and try again."
    case .noMicrophone: "No microphone is available."
    case .couldNotStart(let step, let error):
      "Couldn't start listening (\(step.rawValue)): \(error.localizedDescription)"
    }
  }
}

/// The steps of starting to listen, so a failure says which one went wrong.
enum ListeningStep: String {
  case audioSession = "audio session"
  case speechFormat = "speech format"
  case recogniser = "recogniser"
  case microphone = "microphone"
}

private let log = Logger(subsystem: "dev.leostera.axo.phone", category: "dictation")

/// Runs `work`, labelling any error with the step it happened in.
private func during<T>(_ step: ListeningStep, _ work: () async throws -> T) async throws -> T {
  do {
    return try await work()
  } catch let error as AppleDictationError {
    throw error
  } catch {
    let nsError = error as NSError
    log.error("dictation.start_failed step=\(step.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
    throw AppleDictationError.couldNotStart(step, error)
  }
}

/// Listens with the microphone and turns speech into words on the iPhone, with Apple's
/// SpeechAnalyzer: audio never leaves the device, and words appear while they are spoken.
@available(iOS 26, *)
@MainActor
final class AppleDictation: DictationEngine {
  private var locale: Locale?
  private var listening: Listening?
  private var observers: [NSObjectProtocol] = []

  /// One dictation: the microphone, the recogniser, and what it has settled on.
  private final class Listening {
    let audio = AVAudioEngine()
    let analyzer: SpeechAnalyzer
    let input: AsyncStream<AnalyzerInput>.Continuation
    let level: AudioLevel
    var results: Task<String, Error>?

    init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, level: AudioLevel) {
      self.analyzer = analyzer
      self.input = input
      self.level = level
    }
  }

  var audioLevel: Double { listening?.level.value ?? 0 }

  func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws {
    guard SpeechTranscriber.isAvailable else { throw AppleDictationError.unavailable }
    progress(VoiceSetupProgress(stage: .checking))
    var supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
    if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
    guard let locale = supported else { throw AppleDictationError.unsupportedLanguage }
    // Keep this language's model on the device for Axo; Apple shares and manages the files.
    _ = try await AssetInventory.reserve(locale: locale)
    let module = Self.transcriber(locale)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
      let reporter = Task { @MainActor in
        while !Task.isCancelled {
          progress(VoiceSetupProgress(stage: .downloading, fraction: request.progress.fractionCompleted))
          try? await Task.sleep(for: .milliseconds(200))
        }
      }
      defer { reporter.cancel() }
      try await withTaskCancellationHandler {
        try await request.downloadAndInstall()
      } onCancel: {
        request.progress.cancel()
      }
    }
    try Task.checkCancellation()
    progress(VoiceSetupProgress(stage: .finishing))
    guard await AssetInventory.status(forModules: [module]) == .installed else { throw AppleDictationError.modelNotReady }
    self.locale = locale
  }

  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws {
    await cancel()
    guard let locale else { throw AppleDictationError.modelNotReady }
    do {
      // Recording only, unprocessed as speech recognition wants it. (`.spokenAudio` is a
      // playback mode; with `.record` the session refuses it with OSStatus -50.)
      try await during(.audioSession) {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
        try session.setActive(true)
      }
      let module = Self.transcriber(locale)
      let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
      let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
      let listening = Listening(analyzer: analyzer, input: input, level: AudioLevel())
      self.listening = listening

      let microphone = listening.audio.inputNode.outputFormat(forBus: 0)
      guard microphone.sampleRate > 0, microphone.channelCount > 0 else { throw AppleDictationError.noMicrophone }
      guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: microphone)
      else { throw AppleDictationError.modelNotReady }
      try await during(.speechFormat) { try await analyzer.prepareToAnalyze(in: format) }

      listening.results = Task { @MainActor in
        var settled = AttributedString()
        for try await result in module.results {
          if result.isFinal {
            settled.append(result.text)
            heard(HeardText(settled: String(settled.characters)))
          } else {
            heard(HeardText(settled: String(settled.characters), tentative: String(result.text.characters)))
          }
        }
        return String(settled.characters)
      }
      try await during(.recogniser) { try await analyzer.start(inputSequence: stream) }
      try await during(.microphone) {
        guard Self.tap(listening.audio.inputNode, from: microphone, to: format, into: input, level: listening.level) else {
          throw AppleDictationError.noMicrophone
        }
        listening.audio.prepare()
        try listening.audio.start()
      }
      watch(for: interrupted)
    } catch {
      await cancel()
      throw error
    }
  }

  func finish() async throws -> String {
    guard let listening else { return "" }
    stopAudio(listening)
    try await listening.analyzer.finalizeAndFinishThroughEndOfInput()
    let text = try await listening.results?.value ?? ""
    if self.listening === listening { self.listening = nil }
    return text
  }

  func cancel() async {
    guard let listening else { return }
    self.listening = nil
    stopAudio(listening)
    listening.results?.cancel()
    await listening.analyzer.cancelAndFinishNow()
  }

  private func stopAudio(_ listening: Listening) {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    listening.audio.inputNode.removeTap(onBus: 0)
    listening.audio.stop()
    listening.input.finish()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// A call, Siri, or the headphones going away take the microphone; listening ends there.
  private func watch(for interrupted: @escaping @MainActor () -> Void) {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
      guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            type == AVAudioSession.InterruptionType.began.rawValue else { return }
      Task { @MainActor in interrupted() }
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
      guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
      Task { @MainActor in interrupted() }
    })
  }

  private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
    SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
  }

  /// Runs on the audio thread, so it is built here, away from the main actor: each buffer is
  /// measured for the waveform and converted to the recogniser's format.
  nonisolated private static func tap(
    _ node: AVAudioInputNode, from microphone: AVAudioFormat, to format: AVAudioFormat,
    into input: AsyncStream<AnalyzerInput>.Continuation, level: AudioLevel
  ) -> Bool {
    let needsConverting = microphone != format
    let converter = needsConverting ? AVAudioConverter(from: microphone, to: format) : nil
    // A converter the system will not make would otherwise mean feeding the recogniser audio
    // in a format it did not ask for.
    if needsConverting && converter == nil { return false }
    node.installTap(onBus: 0, bufferSize: 4096, format: microphone) { buffer, _ in
      level.measure(buffer)
      guard let converter else {
        input.yield(AnalyzerInput(buffer: buffer))
        return
      }
      let ratio = format.sampleRate / microphone.sampleRate
      let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
      guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      nonisolated(unsafe) var consumed = false
      var error: NSError?
      converter.convert(to: converted, error: &error) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
      }
      if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
    }
    return true
  }
}

/// The microphone's loudness, written on the audio thread and read by the waveform.
final class AudioLevel: Sendable {
  private let current = OSAllocatedUnfairLock(initialState: 0.0)

  var value: Double { current.withLock { $0 } }

  func measure(_ buffer: AVAudioPCMBuffer) {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
    let rms = Double((sum / Float(buffer.frameLength)).squareRoot())
    current.withLock { $0 = rms.isFinite ? min(1, rms) : 0 }
  }
}

#if DEBUG
/// The simulator preview's stand-in: no microphone, no model download, words that arrive as if
/// spoken.
@MainActor
final class PreviewDictation: DictationEngine {
  private var words: Task<Void, Never>?
  private var said = ""
  var audioLevel: Double { words == nil ? 0 : Double.random(in: 0.02...0.3) }

  func requestPermission() async -> Bool { true }
  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws {
    progress(VoiceSetupProgress(stage: .downloading, fraction: 0.5))
    try await Task.sleep(for: .milliseconds(300))
  }
  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws {
    said = ""
    words = Task { @MainActor in
      for word in ["Make", "the", "tests", "pass"] {
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        said += (said.isEmpty ? "" : " ") + word
        heard(HeardText(settled: said))
      }
    }
  }
  func finish() async throws -> String {
    words?.cancel()
    words = nil
    return said.isEmpty ? "Make the tests pass" : said
  }
  func cancel() async {
    words?.cancel()
    words = nil
  }
}
#endif
