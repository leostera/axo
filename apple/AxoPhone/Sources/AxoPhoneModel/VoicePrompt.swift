import Foundation
import Observation

/// What has been heard so far while listening: words the recogniser has settled on, and the
/// guess it is still making about the last few.
public struct HeardText: Equatable, Sendable {
  public var settled: String
  public var tentative: String

  public init(settled: String = "", tentative: String = "") {
    self.settled = settled
    self.tentative = tentative
  }

  public var isEmpty: Bool { settled.isEmpty && tentative.isEmpty }
}

/// How far getting the on-device speech model ready has got.
public struct VoiceSetupProgress: Equatable, Sendable {
  public enum Stage: Equatable, Sendable { case checking, downloading, finishing }

  public let stage: Stage
  /// 0...1, only meaningful while downloading.
  public let fraction: Double

  public init(stage: Stage, fraction: Double = 0) {
    self.stage = stage
    self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
  }
}

public enum VoicePromptState: Equatable, Sendable {
  case idle
  case requestingPermission
  case preparing(VoiceSetupProgress)
  case listening(HeardText)
  /// Listening stopped; the last words are being settled.
  case finishing
  case failed(String)
}

/// What to do with the words once listening ends. Only an explicit Send sends; anything else
/// (Stop, the recogniser ending on its own) puts them in the box to read first.
public enum VoiceDelivery: Equatable, Sendable { case draft, send }

/// The words of one dictation, and what the person asked to do with them.
public struct VoiceTranscript: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let text: String
  public let delivery: VoiceDelivery

  public init(id: UUID = UUID(), text: String, delivery: VoiceDelivery) {
    self.id = id
    self.text = text
    self.delivery = delivery
  }

  /// After what is already typed: what was typed while listening is kept, and nothing dictated
  /// is cut.
  public func appending(to draft: String) -> String {
    guard !draft.isEmpty else { return text }
    return draft + (draft.last?.isWhitespace == true ? "" : " ") + text
  }
}

/// The microphone and the recogniser, as one: the app's is Apple's on-device speech; tests and the
/// simulator preview use stand-ins.
@MainActor
public protocol DictationEngine: AnyObject {
  /// Loudness now, 0...1, read only while the waveform is on screen.
  var audioLevel: Double { get }
  func requestPermission() async -> Bool
  /// Makes sure the speech model is on the device, downloading it if needed. Done once.
  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws
  /// Starts listening. What is heard arrives through `heard`; `interrupted` says the audio was
  /// taken away (a call, the headphones unplugged) and listening is over.
  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws
  /// Stops listening and returns everything heard, settled.
  func finish() async throws -> String
  /// Stops listening and forgets what was heard.
  func cancel() async
}

public enum VoicePromptError: LocalizedError, Equatable {
  case microphoneDenied
  case noSpeech
  case interrupted

  public var errorDescription: String? {
    switch self {
    case .microphoneDenied: "Microphone access is off. Turn it on for Axo in Settings, then try again."
    case .noSpeech: "Nothing was heard. Try again a little closer to the microphone."
    case .interrupted: "Listening was interrupted. Try again."
    }
  }
}

/// Voice prompting: one dictation at a time. Tap to listen (setting up the speech model the first
/// time), see the words as they are heard, then Stop to put them in the box or Send to send them.
/// Words heard after a cancel never come back, and a finished dictation is handed over once, as
/// `transcript`.
@MainActor @Observable
public final class VoicePrompt {
  public private(set) var state: VoicePromptState = .idle
  /// The last finished dictation, for the screen to put in the box or send.
  public private(set) var transcript: VoiceTranscript?

  @ObservationIgnored private let engine: any DictationEngine
  @ObservationIgnored private var prepared = false
  /// Each dictation's own number: what an older one reports after a cancel is ignored.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var work: Task<Void, Never>?

  public init(engine: any DictationEngine) {
    self.engine = engine
  }

  public var isListening: Bool { if case .listening = state { true } else { false } }

  /// Doing something: the box should wait, and so should switching chats.
  public var isBusy: Bool {
    switch state {
    case .idle, .failed: false
    case .requestingPermission, .preparing, .listening, .finishing: true
    }
  }

  public var audioLevel: Double {
    let level = engine.audioLevel
    return level.isFinite ? min(1, max(0, level)) : 0
  }

  /// Asks for the microphone, sets up the speech model if it is not yet, and starts listening:
  /// one tap, however much of that is needed.
  public func start() {
    guard !isBusy else { return }
    transcript = nil
    generation += 1
    let current = generation
    state = .requestingPermission
    work = Task { [self] in
      defer { if current == generation { work = nil } }
      guard await engine.requestPermission() else { return fail(.microphoneDenied, current) }
      guard current == generation else { return }
      do {
        if !prepared {
          state = .preparing(VoiceSetupProgress(stage: .checking))
          try await engine.prepare { [weak self] progress in
            guard let self, current == self.generation, case .preparing = self.state else { return }
            self.state = .preparing(progress)
          }
          guard current == generation else { return }
          prepared = true
        }
        state = .listening(HeardText())
        try await engine.start(
          heard: { [weak self] heard in
            guard let self, current == self.generation, self.isListening else { return }
            self.state = .listening(heard)
          },
          interrupted: { [weak self] in
            guard let self, current == self.generation, self.isListening else { return }
            self.cancel(because: .interrupted)
          })
        guard current == generation else { return await engine.cancel() }
      } catch {
        guard current == generation else { return }
        await engine.cancel()
        state = .failed(error.localizedDescription)
      }
    }
  }

  /// Stops listening; the words go to the box (`.draft`) or are sent (`.send`).
  public func finish(_ delivery: VoiceDelivery) {
    guard case .listening = state else { return }
    let current = generation
    state = .finishing
    work = Task { [self] in
      defer { if current == generation { work = nil } }
      do {
        let text = try await engine.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == generation else { return }
        guard !text.isEmpty else { return fail(.noSpeech, current) }
        transcript = VoiceTranscript(text: text, delivery: delivery)
        state = .idle
      } catch {
        guard current == generation else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  /// Stops whatever is happening and forgets it: nothing heard reaches the box.
  public func cancel() { cancel(because: nil) }

  /// Takes a failure off the screen.
  public func dismissFailure() {
    if case .failed = state { state = .idle }
  }

  /// The screen has put `transcript` in the box or sent it.
  public func consume(_ transcript: VoiceTranscript) {
    if self.transcript?.id == transcript.id { self.transcript = nil }
  }

  private func cancel(because reason: VoicePromptError?) {
    guard isBusy else { return }
    generation += 1
    work?.cancel()
    work = nil
    transcript = nil
    state = reason.map { .failed($0.localizedDescription) } ?? .idle
    Task { [engine] in await engine.cancel() }
  }

  private func fail(_ error: VoicePromptError, _ current: Int) {
    guard current == generation else { return }
    state = .failed(error.localizedDescription)
  }
}

/// How tall a waveform bar is for a loudness: quiet speech shows, silence stays flat, and loud
/// speech (−18 dB and up) is full height.
public enum VoiceWaveformScale {
  public static func heightFraction(for amplitude: Double) -> Double {
    guard amplitude.isFinite, amplitude > 0 else { return 0 }
    let decibels = 20 * log10(min(1, amplitude))
    return pow(min(1, max(0, (decibels + 60) / 42)), 0.7)
  }
}
