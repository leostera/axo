import Foundation
import Observation

public enum VoicePreparationStage: Sendable { case checking, downloading, loading }

public struct DownloadBytes: Sendable, Equatable {
    public let downloaded: Int64
    public let total: Int64

    public init?(downloaded: Int64, total: Int64) {
        guard downloaded >= 0, total > 0 else { return nil }
        self.downloaded = min(downloaded, total)
        self.total = total
    }

    public var formatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = true
        return formatter.string(fromByteCount: downloaded) + " / " + formatter.string(fromByteCount: total)
    }
}

public struct VoiceModelProgress: Sendable, Equatable {
    public let fraction: Double
    public let detail: String
    public let stage: VoicePreparationStage
    public let bytes: DownloadBytes?

    public init(fraction: Double, detail: String, stage: VoicePreparationStage = .checking, bytes: DownloadBytes? = nil) {
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.detail = detail
        self.stage = stage
        self.bytes = bytes
    }
}

public enum VoicePromptState: Equatable {
    case idle
    case preparing(VoiceModelProgress)
    case ready
    case requestingPermission
    case recording
    case transcribing
    case cancelling
    case failed(String)
}

public enum VoiceTranscriptDelivery: Equatable, Sendable { case draft, send }

public struct VoiceTranscript: Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let delivery: VoiceTranscriptDelivery

    public init(text: String, delivery: VoiceTranscriptDelivery = .draft) {
        self.text = text
        self.delivery = delivery
    }

    /// Preserve edits made while recognition was running; never truncate dictated text.
    public func appending(to draft: String) -> String {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : "\n"
        return draft + separator + text
    }
}

public protocol LocalSpeechTranscribing: Sendable {
    func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws
    func transcribe(_ audioURL: URL) async throws -> String
    func unload() async
}

@MainActor
public protocol VoiceRecording: AnyObject {
    var onFinished: (() -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    /// Normalized microphone amplitude, queried only while capture is visible.
    var audioLevel: Double { get }
    func requestPermission() async -> Bool
    func start() throws
    /// Stops capture and transfers ownership of the temporary file to the caller.
    func stop() throws -> URL
    /// Stops capture and removes any file still owned by the recorder.
    func cancel()
}

public extension VoiceRecording {
    var audioLevel: Double { 0 }
}

public enum VoicePromptError: LocalizedError {
    case microphoneDenied, recorderUnavailable, invalidClip, noSpeech

    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable it for Axo in Settings, then try again."
        case .recorderUnavailable: "Could not start the microphone. Check the audio input and try again."
        case .invalidClip: "Record at least a quarter-second of speech."
        case .noSpeech: "No speech was detected. Try recording again."
        }
    }
}

/// One operation at a time, including cancellation cleanup. Late recognition results
/// must never reappear after cancellation or overwrite the user's current draft.
@MainActor @Observable
public final class VoicePrompt {
    public private(set) var state: VoicePromptState = .idle
    public private(set) var transcript: VoiceTranscript?

    @ObservationIgnored private let recorder: any VoiceRecording
    @ObservationIgnored private let transcriber: any LocalSpeechTranscribing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var cancellationState: VoicePromptState?

    public init(recorder: any VoiceRecording, transcriber: any LocalSpeechTranscribing) {
        self.recorder = recorder
        self.transcriber = transcriber
        recorder.onFinished = { [weak self] in self?.finishRecording() }
        recorder.onInterrupted = { [weak self] in
            self?.cancel(reason: "Recording was interrupted. Please try again.")
        }
    }

    public var isBusy: Bool {
        switch state {
        case .idle, .ready, .failed: false
        default: true
        }
    }

    private enum PreparationIntent { case warmUp, record }

    /// Call only after the user consents to the model download.
    public func prepare() { prepare(intent: .warmUp) }

    /// One user action covers setup and capture; no second record tap is required.
    public func prepareAndRecord() {
        if state == .ready { startRecording() }
        else { prepare(intent: .record) }
    }

    private func prepare(intent: PreparationIntent) {
        guard !isBusy else { return }
        if intent == .record { transcript = nil }
        perform(starting: .requestingPermission) { [self] id in
            guard await self.recorder.requestPermission() else { throw VoicePromptError.microphoneDenied }
            try Task.checkCancellation()
            self.state = .preparing(.init(fraction: 0, detail: "Preparing Apple on-device speech"))
            try await self.transcriber.prepare { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.operationID == id, case .preparing = self.state else { return }
                    self.state = .preparing(progress)
                }
            }
            try Task.checkCancellation()
            if intent == .record {
                try self.recorder.start()
                return .recording
            }
            return .ready
        }
    }

    public func startRecording() {
        guard state == .ready else { return }
        transcript = nil
        perform(starting: .requestingPermission) { _ in
            guard await self.recorder.requestPermission() else { throw VoicePromptError.microphoneDenied }
            try Task.checkCancellation()
            try self.recorder.start()
            return .recording
        }
    }

    public var audioLevel: Double {
        let level = recorder.audioLevel
        return level.isFinite ? min(1, max(0, level)) : 0
    }

    /// Automatic recorder completion defaults to a draft; only explicit Send
    /// authorizes submission. Bind that decision to this transcription result.
    public func finishRecording(delivery: VoiceTranscriptDelivery = .draft) {
        guard state == .recording, task == nil else { return }
        // Change state before stop(), whose delegate can also report completion.
        state = .transcribing
        do {
            let audioURL = try recorder.stop()
            perform(starting: .transcribing) { _ in
                defer { try? FileManager.default.removeItem(at: audioURL) }
                let text = try await self.transcriber.transcribe(audioURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { throw VoicePromptError.noSpeech }
                self.transcript = VoiceTranscript(text: text, delivery: delivery)
                return .ready
            }
        } catch {
            recorder.cancel()
            state = .failed(error.localizedDescription)
        }
    }

    /// Also used when backgrounding: stop the mic now, then release models once
    /// outstanding analysis has unwound. Do not unload under an in-flight decode.
    public func cancel(reason: String? = nil) {
        recorder.cancel()
        transcript = nil
        let next: VoicePromptState = reason.map { .failed($0) } ?? .idle
        if let task {
            cancellationState = next
            state = .cancelling
            task.cancel()
        } else {
            perform(starting: .cancelling) { _ in
                await self.transcriber.unload()
                return next
            }
        }
    }

    private func perform(
        starting state: VoicePromptState,
        operation: @escaping @MainActor (UUID) async throws -> VoicePromptState
    ) {
        guard task == nil else { return }
        let id = UUID()
        operationID = id
        cancellationState = nil
        self.state = state
        task = Task {
            var next: VoicePromptState
            do {
                next = try await operation(id)
                try Task.checkCancellation()
            } catch {
                self.recorder.cancel()
                await self.transcriber.unload()
                next = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            if let cancelled = self.cancellationState {
                await self.transcriber.unload()
                self.transcript = nil
                next = cancelled
            }
            self.operationID = nil
            self.cancellationState = nil
            self.task = nil
            self.state = next
        }
    }
}
