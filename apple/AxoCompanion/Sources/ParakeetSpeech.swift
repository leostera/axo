#if os(iOS) || os(macOS)
import CoreML
import FluidAudio
import Foundation

public enum ParakeetProgress: Sendable {
  case checking, downloading(Double), loading
}

public enum ParakeetError: LocalizedError, Equatable, Sendable {
  case modelNotReady, modelDownload, modelLoad, busy, transcription

  public var errorDescription: String? {
    switch self {
    case .modelNotReady: "Open Axo on your iPhone and tap the microphone to set up English dictation."
    case .modelDownload: "Couldn't download the English dictation model. Check your connection and free space, then try again."
    case .modelLoad: "Couldn't load the English dictation model on this device."
    case .busy: "Axo is already transcribing on this device. Try again shortly."
    case .transcription: "English dictation couldn't transcribe this recording."
    }
  }
}

/// One inference engine across live dictation and Watch audio. It is loaded only while leased;
/// no concurrently running recognizers, unbounded work queue, or alternate transcription service.
public actor ParakeetSpeech {
  public static let shared = ParakeetSpeech()
  public static let sampleRate = 16_000
  public static let maximumSamples = sampleRate * 90

  private let cacheRoot: URL
  private var owner: UUID?
  private var manager: AsrManager?
  private var active = false
  private var retiring = false

  init(cacheRoot: URL = URL.cachesDirectory.appendingPathComponent("AxoParakeet", isDirectory: true)) {
    self.cacheRoot = cacheRoot
  }

  public func prepare(
    for id: UUID, allowDownload: Bool,
    progress: @escaping @Sendable (ParakeetProgress) -> Void = { _ in }
  ) async throws {
    try Task.checkCancellation()
    guard owner == nil else { throw ParakeetError.busy }
    owner = id
    active = true
    defer { finishedOperation() }

    do {
      let directory: URL
      do {
        directory = try await ParakeetAssets.directory(in: cacheRoot, allowDownload: allowDownload, progress: progress)
      } catch {
        try Task.checkCancellation()
        throw error as? ParakeetError ?? .modelDownload
      }
      progress(.loading)
      let loaded: AsrManager
      do { loaded = try await Self.load(from: directory) }
      catch {
        try Task.checkCancellation()
        throw ParakeetError.modelLoad
      }
      try Task.checkCancellation()
      guard !retiring else { throw CancellationError() }
      manager = loaded
    } catch {
      retiring = true
      throw error
    }
  }

  public func release(_ id: UUID) {
    guard owner == id else { return }
    retiring = true
    if !active { finishedOperation() }
  }

  private func finishedOperation() {
    active = false
    if retiring {
      manager = nil
      owner = nil
      retiring = false
    }
  }

  public func transcribe(_ samples: [Float], for id: UUID) async throws -> String {
    guard samples.count <= Self.maximumSamples else { throw ParakeetError.transcription }
    // v2 requires at least one 320 ms encoder window. Pad very short clips rather than
    // asking the decoder to treat a tiny tail as a complete utterance.
    guard !samples.isEmpty else { return "" }
    let minimum = Self.sampleRate / 2
    let input = samples.count < minimum ? samples + Array(repeating: 0, count: minimum - samples.count) : samples
    return try await recognize(for: id) { manager, state in
      try await manager.transcribe(input, decoderState: &state)
    }
  }

  func transcribeFile(_ url: URL, for id: UUID) async throws -> String {
    try await recognize(for: id) { manager, state in
      try await manager.transcribe(url, decoderState: &state)
    }
  }

  private func recognize(
    for id: UUID, run: (AsrManager, inout TdtDecoderState) async throws -> ASRResult
  ) async throws -> String {
    try Task.checkCancellation()
    guard owner == id, let manager, !active, !retiring else { throw ParakeetError.busy }
    active = true
    defer { finishedOperation() }
    do {
      var decoder = TdtDecoderState.make()
      let result = try await run(manager, &decoder)
      try Task.checkCancellation()
      guard !retiring else { throw CancellationError() }
      return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      try Task.checkCancellation()
      if retiring { throw CancellationError() }
      throw ParakeetError.transcription
    }
  }

  private static func load(from directory: URL) async throws -> AsrManager {
    // Don't use FluidAudio's automatic download/recovery paths (they may follow a moving
    // revision). Load these four local files explicitly. Avoid GPU in Watch background wakes.
    let config = AsrModels.defaultConfiguration()
    let cpu = MLModelConfiguration()
    cpu.computeUnits = .cpuOnly
    func model(_ name: String, configuration: MLModelConfiguration) async throws -> MLModel {
      try Task.checkCancellation()
      return try await MLModel.load(contentsOf: directory.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
    }
    let vocab = try JSONDecoder().decode([Int: String].self,
      from: Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json")))
    let models = try await AsrModels(
      encoder: model("Encoder", configuration: config),
      preprocessor: model("Preprocessor", configuration: cpu),
      decoder: model("Decoder", configuration: config),
      joint: model("JointDecision", configuration: config),
      configuration: config, vocabulary: vocab, version: .v2)
    let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
    try await manager.loadModels(models)
    return manager
  }
}
#endif
