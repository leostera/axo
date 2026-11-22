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
  /// Captured when recording starts; only an explicit new-draft host choice may move it.
  public let destination: PhoneWorkbench.Selection?

  public init(id: UUID = UUID(), text: String, delivery: VoiceDelivery, destination: PhoneWorkbench.Selection? = nil) {
    self.id = id
    self.text = text
    self.delivery = delivery
    self.destination = destination
  }

  /// After what is already typed: what was typed while listening is kept, and nothing dictated
  /// is cut.
  public func appending(to draft: String) -> String {
    guard !draft.isEmpty else { return text }
    return draft + (draft.last?.isWhitespace == true ? "" : " ") + text
  }
}

/// The microphone and the on-device recognizer, as one.
@MainActor
public protocol DictationEngine: AnyObject {
  /// Loudness now, 0...1, read only while the waveform is on screen.
  var audioLevel: Double { get }
  func requestPermission() async -> Bool
  /// Whether preparation must run again after the previous recording released the recognizer.
  var needsPreparationEachTime: Bool { get }
  /// Makes sure the speech model is ready, downloading it if needed.
  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws
  /// Starts listening. What is heard arrives through `heard`; `interrupted` says the audio was
  /// taken away (a call, the headphones unplugged) and listening is over.
  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws
  /// Stops listening and returns everything heard, settled.
  func finish() async throws -> String
  /// Stops listening and forgets what was heard.
  func cancel() async
}

public extension DictationEngine {
  var needsPreparationEachTime: Bool { false }
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
  public private(set) var transcript: VoiceTranscript? {
    didSet { if let transcript { checkpoint?(transcript) } }
  }
  /// Synchronous local checkpoints; restoring one is always a draft, never a Send.
  @ObservationIgnored public var checkpoint: (@MainActor (VoiceTranscript?) -> Void)?
  @ObservationIgnored private var recordingID = UUID()

  @ObservationIgnored private let engine: any DictationEngine
  @ObservationIgnored private var prepared = false
  /// Each dictation's own number: what an older one reports after a cancel is ignored.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var cleanup: Task<Void, Never>?
  @ObservationIgnored private var lastHeard = HeardText()
  @ObservationIgnored private var destination: PhoneWorkbench.Selection?
  @ObservationIgnored private var destinationRevision = 0

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
  public func start(in destination: PhoneWorkbench.Selection? = nil) {
    guard !isBusy, transcript == nil else { return }
    self.destination = destination
    recordingID = UUID()
    lastHeard = HeardText()
    generation += 1
    let current = generation
    state = .requestingPermission
    let retiring = cleanup
    work = Task { [self] in
      defer { if current == generation { work = nil } }
      await retiring?.value
      guard current == generation else { return }
      guard await engine.requestPermission() else { return fail(.microphoneDenied, current) }
      guard current == generation else { return }
      do {
        if !prepared || engine.needsPreparationEachTime {
          state = .preparing(VoiceSetupProgress(stage: .checking))
          try await engine.prepare { [weak self] progress in
            guard let self, current == self.generation, case .preparing = self.state else { return }
            self.state = .preparing(progress)
          }
          guard current == generation else { return }
          prepared = true
        }
        // Don't offer Stop/Send until start actually owns a running microphone.
        state = .preparing(VoiceSetupProgress(stage: .finishing))
        try await engine.start(
          heard: { [weak self] heard in
            guard let self, current == self.generation, self.isBusy else { return }
            self.lastHeard = heard
            self.checkpointHeard()
            if self.isListening { self.state = .listening(heard) }
          },
          interrupted: { [weak self] in
            guard let self, current == self.generation, self.isBusy else { return }
            self.interrupt()
          })
        guard current == generation else { return await engine.cancel() }
        state = .listening(lastHeard)
      } catch {
        guard current == generation else { return }
        await engine.cancel()
        guard current == generation else { return }
        if !recoverHeardDraft() { state = .failed(error.localizedDescription) }
      }
    }
  }

  /// A new chat changes its execution host, not the recording or the message being composed.
  /// Ordinary navigation must never call this: existing chats retain their original destination.
  public func retargetNewChat(from previous: PhoneWorkbench.Selection, to next: PhoneWorkbench.Selection) {
    guard previous.session == nil, next.session == nil, destination == previous else { return }
    destination = next
    if transcript == nil { checkpointHeard() }
    destinationOptionsChanged()
    if let transcript {
      self.transcript = VoiceTranscript(id: transcript.id, text: transcript.text, delivery: .draft, destination: next)
    }
  }

  public func isTargeting(_ selection: PhoneWorkbench.Selection?) -> Bool {
    selection != nil && destination == selection && (isBusy || transcript != nil)
  }

  /// A Send already being finalized must be reviewed after the host or agent changes.
  /// Recording itself continues; a subsequent explicit Send uses the newly selected options.
  public func destinationOptionsChanged() {
    destinationRevision += 1
    if let transcript, transcript.delivery == .send {
      self.transcript = VoiceTranscript(id: transcript.id, text: transcript.text, delivery: .draft, destination: transcript.destination)
    }
  }

  /// Stops listening; the words go to the box (`.draft`) or are sent (`.send`).
  public func finish(_ delivery: VoiceDelivery) {
    guard case .listening = state else { return }
    let current = generation
    let destinationAtSend = destinationRevision
    state = .finishing
    work = Task { [self] in
      defer { if current == generation { work = nil } }
      do {
        let text = try await engine.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == generation else { return }
        guard !text.isEmpty else {
          if !recoverHeardDraft() { fail(.noSpeech, current) }
          return
        }
        transcript = VoiceTranscript(id: recordingID, text: text, delivery: destinationAtSend == destinationRevision ? delivery : .draft, destination: destination)
        state = .idle
      } catch {
        guard current == generation else { return }
        await engine.cancel()
        guard current == generation else { return }
        if !recoverHeardDraft() { state = .failed(error.localizedDescription) }
      }
    }
  }

  /// A lock/call is not Cancel: keep even tentative recognized words for review, never send.
  public func interrupt(_ error: any Error = VoicePromptError.interrupted) {
    guard isBusy else { return }
    retireWork()
    if !recoverHeardDraft() { state = .failed(error.localizedDescription) }
  }

  @discardableResult
  private func recoverHeardDraft() -> Bool {
    let text = (lastHeard.settled + lastHeard.tentative).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    transcript = VoiceTranscript(id: recordingID, text: text, delivery: .draft, destination: destination)
    state = .idle
    return true
  }

  /// Stops whatever is happening and forgets it: nothing heard reaches the box.
  public func cancel() {
    guard isBusy else { return }
    retireWork()
    transcript = nil
    lastHeard = HeardText()
    checkpoint?(nil)
    state = .idle
  }

  private func checkpointHeard() {
    let text = (lastHeard.settled + lastHeard.tentative).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    checkpoint?(VoiceTranscript(id: recordingID, text: text, delivery: .draft, destination: destination))
  }

  /// Takes a failure off the screen.
  public func dismissFailure() {
    if case .failed = state { state = .idle }
  }

  /// The screen has put `transcript` in the box or sent it.
  @discardableResult
  public func consume(_ transcript: VoiceTranscript) -> Bool {
    guard self.transcript?.id == transcript.id else { return false }
    self.transcript = nil
    return true
  }

  /// An old asynchronous start/finalize must retire before another recording uses the engine.
  private func retireWork() {
    generation += 1
    let previous = work
    let retiring = cleanup
    previous?.cancel()
    work = nil
    cleanup = Task { [engine] in
      await retiring?.value
      await engine.cancel()
      await previous?.value
      await engine.cancel()
    }
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
