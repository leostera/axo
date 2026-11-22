import AVFoundation
import AxoCompanion
import AxoMobileModel
import Foundation
import UIKit
import os

@MainActor
enum Dictation {
  static func makeVoicePrompt() -> VoicePrompt? {
    #if DEBUG
    if PreviewFixture.requested { return VoicePrompt(engine: PreviewDictation()) }
    #endif
    let engine = ParakeetDictation()
    let voice = VoicePrompt(engine: engine)
    engine.onLimit = { [weak voice] in voice?.finish(.draft) }
    engine.onError = { [weak voice] error in voice?.interrupt(error) }
    return voice
  }
}

private enum MicrophoneError: LocalizedError {
  case unavailable, conversion, start(any Error)

  var errorDescription: String? {
    switch self {
    case .unavailable: "No microphone is available."
    case .conversion: "Couldn't read the microphone. Reconnect it and try again."
    case .start(let error): "Couldn't start the microphone: \(error.localizedDescription)"
    }
  }
}

@MainActor
private final class ParakeetDictation: DictationEngine {
  private let speech = ParakeetSpeech.shared
  private var owner: UUID?
  private var listening: Listening?
  private let wake = RecordingWakeLock(
    read: { UIApplication.shared.isIdleTimerDisabled },
    write: { UIApplication.shared.isIdleTimerDisabled = $0 })
  var onLimit: (() -> Void)?
  var onError: ((any Error) -> Void)?

  @MainActor
  private final class Listening {
    let engine = AVAudioEngine()
    let pcm = RecordedPCM()
    var observers: [NSObjectProtocol] = []
    var tapInstalled = false
    var stopped = false
    var preview: Task<Void, Never>?
  }

  var audioLevel: Double { listening?.pcm.level ?? 0 }
  var needsPreparationEachTime: Bool { true }

  func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws {
    let id = UUID()
    owner = id
    try await speech.prepare(for: id, allowDownload: true) { update in
      Task { @MainActor in
        switch update {
        case .checking: progress(.init(stage: .checking))
        case .downloading(let fraction): progress(.init(stage: .downloading, fraction: fraction))
        case .loading: progress(.init(stage: .finishing))
        }
      }
    }
  }

  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws {
    try Task.checkCancellation()
    guard let id = owner else { throw ParakeetError.modelNotReady }
    let session = AVAudioSession.sharedInstance()
    let recording = Listening()
    do {
      try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
      try session.setActive(true)
      listening = recording
      let node = recording.engine.inputNode
      let source = node.outputFormat(forBus: 0)
      guard source.sampleRate > 0, source.channelCount > 0 else { throw MicrophoneError.unavailable }
      try Self.installTap(on: node, source: source, pcm: recording.pcm)
      recording.tapInstalled = true
      recording.engine.prepare()
      try recording.engine.start()
    } catch {
      await cancel()
      throw (error as? MicrophoneError) ?? MicrophoneError.start(error)
    }

    wake.acquire()
    observeInterruptions(recording, interrupted: interrupted)
    recording.preview = Task { [weak self, weak recording] in
      var previousCount = 0
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(250))
          guard let self, let recording, self.listening === recording, !recording.stopped else { return }
          let (count, failed) = recording.pcm.status
          if failed { throw MicrophoneError.conversion }
          if count == ParakeetSpeech.maximumSamples {
            // At the cap, settle the whole recording as a draft. Only the Send button sends.
            self.stopAudio(recording)
            self.onLimit?()
            return
          }
          // The encoder is an offline model: periodically revise a tentative full-prefix
          // transcript. Longer prompts get fewer re-decodes; never enqueue a preview.
          let rate = ParakeetSpeech.sampleRate
          let stride = count <= 15 * rate ? 2 * rate : 5 * rate
          guard count - previousCount >= stride else { continue }
          let samples = recording.pcm.snapshot()
          let text = try await self.speech.transcribe(samples, for: id)
          try Task.checkCancellation()
          guard self.listening === recording, !recording.stopped else { return }
          previousCount = samples.count
          heard(HeardText(tentative: text))
        } catch {
          if !Task.isCancelled, let self, let recording, self.listening === recording, !recording.stopped {
            self.onError?(error)
          }
          return
        }
      }
    }
  }

  func finish() async throws -> String {
    guard let listening, let id = owner else { return "" }
    stopAudio(listening)
    listening.preview?.cancel()
    await listening.preview?.value
    try Task.checkCancellation()
    guard self.listening === listening, owner == id else { throw CancellationError() }
    guard !listening.pcm.status.failed else { throw MicrophoneError.conversion }
    let text = try await speech.transcribe(listening.pcm.snapshot(), for: id)
    try Task.checkCancellation()
    await cancel()
    return text
  }

  func cancel() async {
    let id = owner
    owner = nil
    let recording = listening
    listening = nil
    if let recording {
      stopAudio(recording)
      recording.preview?.cancel()
      recording.pcm.discard()
    }
    if let id { await speech.release(id) }
    await recording?.preview?.value
  }

  private func stopAudio(_ recording: Listening) {
    guard !recording.stopped else { return }
    recording.stopped = true
    for observer in recording.observers { NotificationCenter.default.removeObserver(observer) }
    recording.observers.removeAll()
    if recording.tapInstalled { recording.engine.inputNode.removeTap(onBus: 0) }
    recording.engine.stop()
    wake.release()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func observeInterruptions(_ recording: Listening, interrupted: @escaping @MainActor () -> Void) {
    let center = NotificationCenter.default
    let onLoss: @Sendable () -> Void = { [weak self, weak recording] in
      Task { @MainActor in
        guard let recording, self?.listening === recording, !recording.stopped else { return }
        interrupted()
      }
    }
    recording.observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { note in
      if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
        onLoss()
      }
    })
    recording.observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { note in
      if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        onLoss()
      }
    })
    recording.observers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { _ in onLoss() })
  }

  /// Keep the converter on the tap's serial audio callback. Never queue input or retain AV buffers.
  nonisolated private static func installTap(on node: AVAudioInputNode, source: AVAudioFormat, pcm: RecordedPCM) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(ParakeetSpeech.sampleRate), channels: 1),
      let converter = AVAudioConverter(from: source, to: format),
      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
    else { throw MicrophoneError.conversion }
    node.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
      guard pcm.canRecord else { return }
      nonisolated(unsafe) var supplied = false
      var error: NSError?
      repeat {
        converted.frameLength = 0
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
          guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
          supplied = true
          inputStatus.pointee = .haveData
          return buffer
        }
        if status == .error || error != nil { pcm.fail(); return }
        pcm.append(converted)
        if status != .haveData || converted.frameLength == 0 { break }
      } while pcm.canRecord
    }
  }
}

/// At most 90 seconds of mono Float32 (~5.8 MB); inference gets a separate bounded snapshot.
private final class RecordedPCM: Sendable {
  private struct State: Sendable {
    var samples: [Float] = []
    var level: Double = 0
    var failed = false
    var discarded = false
  }
  private let storage = OSAllocatedUnfairLock(initialState: State())

  init() { storage.withLock { $0.samples.reserveCapacity(ParakeetSpeech.maximumSamples) } }

  var level: Double { storage.withLock { $0.level } }
  var status: (count: Int, failed: Bool) { storage.withLock { ($0.samples.count, $0.failed) } }
  var canRecord: Bool {
    storage.withLock { !$0.discarded && !$0.failed && $0.samples.count < ParakeetSpeech.maximumSamples }
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    let input = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
    let rms = Double((input.reduce(Float.zero) { $0 + $1 * $1 } / Float(input.count)).squareRoot())
    // The pointer stays on the tap thread for this synchronous copy; it is never stored.
    storage.withLockUnchecked {
      guard !$0.discarded else { return }
      $0.level = rms.isFinite ? min(1, rms) : 0
      $0.samples.append(contentsOf: input.prefix(ParakeetSpeech.maximumSamples - $0.samples.count))
    }
  }

  func snapshot() -> [Float] { storage.withLock { $0.samples.withUnsafeBufferPointer { Array($0) } } }
  func fail() { storage.withLock { $0.failed = true } }
  func discard() {
    storage.withLock {
      $0.discarded = true
      $0.samples.removeAll(keepingCapacity: false)
    }
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
