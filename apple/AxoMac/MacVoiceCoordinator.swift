import AVFoundation
import AxoCore
import AxoVoice
import Foundation
import Observation

struct MacVoiceTarget: Equatable, Sendable {
    let sessionID: AxoSessionID
    let paneID: PaneID
    let runtimeGeneration: UUID
    let workspaceName: String
    let sessionName: String

    var label: String { "\(sessionName) · \(workspaceName)" }
}

struct MacVoiceTranscription: Identifiable, Equatable {
    let id: UUID
    let target: MacVoiceTarget
}

@MainActor @Observable
final class MacVoiceCoordinator {
    private struct Recording {
        let id: UUID
        let target: MacVoiceTarget
    }

    private enum VoiceFault: LocalizedError {
        case tooManyOperations, tooLong
        var errorDescription: String? {
            switch self {
            case .tooManyOperations: "Finish or cancel a voice transcription before starting another recording."
            case .tooLong: "The transcript exceeded Axo's safe insertion limit and was not inserted."
            }
        }
    }

    private(set) var recordingTarget: MacVoiceTarget?
    private(set) var startingTarget: MacVoiceTarget?
    private(set) var preparationProgress: VoiceModelProgress?
    private(set) var transcriptions: [MacVoiceTranscription] = []
    private(set) var transcripts: [MacVoiceTranscript] = []
    private(set) var errorMessage: String?
    private(set) var destinationRevision = 0
    var onActivityChanged: (@MainActor () -> Void)?
    var onTranscriptReady: (@MainActor (MacVoiceTarget, String) -> Bool)?
    var onError: (@MainActor () -> Void)?

    @ObservationIgnored private let recorder: any VoiceRecording
    @ObservationIgnored private let makeTranscriber: @MainActor () -> any LocalSpeechTranscribing
    @ObservationIgnored private let historyStore: MacVoiceHistoryStore?
    @ObservationIgnored private var startingID: UUID?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var recording: Recording?
    @ObservationIgnored private var recordingTranscriber: (any LocalSpeechTranscribing)?
    @ObservationIgnored private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]

    var isStarting: Bool { startingID != nil }
    var isRecording: Bool { recording != nil }
    var isBusy: Bool { isStarting || isRecording || !transcriptions.isEmpty }

    init(recorder: (any VoiceRecording)? = nil,
         historyURL: URL? = nil,
         makeTranscriber: @escaping @MainActor () -> any LocalSpeechTranscribing = { AppleSpeechProvider.makeTranscriber() }) {
        let recorder = recorder ?? MacMicrophoneRecorder()
        self.recorder = recorder
        self.makeTranscriber = makeTranscriber
        historyStore = historyURL.map(MacVoiceHistoryStore.init(fileURL:))
        transcripts = historyStore?.load() ?? []
        recorder.onFinished = { [weak self] in self?.stopCapture() }
        recorder.onInterrupted = { [weak self] in self?.handleInterruption() }
    }

    func startCapture(for target: MacVoiceTarget) {
        guard !isStarting, !isRecording else { return }
        guard transcriptions.count < 2 else { errorMessage = VoiceFault.tooManyOperations.localizedDescription; return }
        errorMessage = nil
        preparationProgress = nil
        let id = UUID()
        startingID = id
        startingTarget = target
        startTask = Task { [weak self] in
            guard let self else { return }
            var transcriber: (any LocalSpeechTranscribing)?
            do {
                guard await self.recorder.requestPermission() else { throw VoicePromptError.microphoneDenied }
                try Task.checkCancellation()
                let newTranscriber = self.makeTranscriber()
                transcriber = newTranscriber
                self.preparationProgress = .init(fraction: 0, detail: "Preparing Apple's on-device speech")
                try await newTranscriber.prepare { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.startingID == id else { return }
                        self.preparationProgress = progress
                    }
                }
                try Task.checkCancellation()
                try self.recorder.start()
                guard self.startingID == id else {
                    self.recorder.cancel()
                    await newTranscriber.unload()
                    return
                }
                self.recording = Recording(id: id, target: target)
                self.recordingTarget = target
                self.recordingTranscriber = newTranscriber
                self.startingID = nil
                self.startingTarget = nil
                self.preparationProgress = nil
                self.startTask = nil
                self.onActivityChanged?()
            } catch {
                self.recorder.cancel()
                if let transcriber { await transcriber.unload() }
                guard self.startingID == id else { return }
                self.startingID = nil
                self.startingTarget = nil
                self.preparationProgress = nil
                self.startTask = nil
                self.errorMessage = error.localizedDescription
                self.onError?()
                self.onActivityChanged?()
            }
        }
    }

    func stopCapture() {
        guard let active = recording, let transcriber = recordingTranscriber else { return }
        recording = nil
        recordingTarget = nil
        recordingTranscriber = nil
        onActivityChanged?()
        do {
            let audioURL = try recorder.stop()
            transcriptions.append(.init(id: active.id, target: active.target))
            transcriptionTasks[active.id] = Task { [weak self] in
                do {
                    defer { try? FileManager.default.removeItem(at: audioURL) }
                    let text = try await transcriber.transcribe(audioURL).trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard !text.isEmpty else { throw VoicePromptError.noSpeech }
                    guard text.utf8.count <= 32_768 else { throw VoiceFault.tooLong }
                    await transcriber.unload()
                    guard let self, self.transcriptions.contains(where: { $0.id == active.id }) else { return }
                    self.transcriptions.removeAll { $0.id == active.id }
                    self.transcriptionTasks.removeValue(forKey: active.id)
                    let inserted = self.onTranscriptReady?(active.target, text) ?? false
                    let transcript = MacVoiceTranscript(
                        id: active.id, createdAt: Date(), workspaceName: active.target.workspaceName,
                        sessionName: active.target.sessionName, text: text,
                        insertion: inserted ? .inserted : .originalPaneUnavailable
                    )
                    self.transcripts.insert(transcript, at: 0)
                    self.transcripts = Array(self.transcripts.prefix(MacVoiceHistoryStore.maximumTranscripts))
                    do { try self.historyStore?.save(self.transcripts) }
                    catch {
                        let delivery = inserted ? "Transcript was inserted" : "Transcript was not inserted"
                        self.errorMessage = "\(delivery), but could not be saved in Voice & Transcripts. \(error.localizedDescription)"
                        self.onError?()
                    }
                } catch {
                    await transcriber.unload()
                    guard let self, self.transcriptions.contains(where: { $0.id == active.id }) else { return }
                    self.transcriptions.removeAll { $0.id == active.id }
                    self.transcriptionTasks.removeValue(forKey: active.id)
                    if !Task.isCancelled {
                        self.errorMessage = error.localizedDescription
                        self.onError?()
                    }
                }
            }
        } catch {
            recorder.cancel()
            Task { await transcriber.unload() }
            errorMessage = error.localizedDescription
            onError?()
        }
    }

    func cancelCapture() {
        if let task = startTask {
            startingID = nil
            startingTarget = nil
            preparationProgress = nil
            startTask = nil
            task.cancel()
            recorder.cancel()
            onActivityChanged?()
            return
        }
        guard let transcriber = recordingTranscriber else { return }
        recording = nil
        recordingTarget = nil
        recordingTranscriber = nil
        recorder.cancel()
        Task { await transcriber.unload() }
        onActivityChanged?()
    }

    func cancelTranscription(_ id: UUID) {
        guard transcriptions.contains(where: { $0.id == id }) else { return }
        transcriptions.removeAll { $0.id == id }
        transcriptionTasks.removeValue(forKey: id)?.cancel()
    }

    func deleteTranscript(_ id: UUID) {
        transcripts.removeAll { $0.id == id }
        do { try historyStore?.save(transcripts) }
        catch { errorMessage = error.localizedDescription; onError?() }
    }

    func clearTranscripts() {
        transcripts.removeAll()
        do { try historyStore?.save(transcripts) }
        catch { errorMessage = error.localizedDescription; onError?() }
    }

    func report(_ message: String) { errorMessage = message; onError?() }
    func destinationStateChanged() { destinationRevision &+= 1 }

    func shutdown() {
        cancelCapture()
        for task in transcriptionTasks.values { task.cancel() }
        transcriptionTasks.removeAll()
        transcriptions.removeAll()
    }

    private func handleInterruption() {
        cancelCapture()
        errorMessage = "Voice recording was interrupted. Start a new recording when ready."
        onError?()
    }
}

@MainActor
final class MacMicrophoneRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?

    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func start() throws {
        cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-voice-\(UUID().uuidString).wav")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            self.recorder = recorder
            audioURL = url
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else { throw VoicePromptError.recorderUnavailable }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard recorder.record() else { throw VoicePromptError.recorderUnavailable }
        } catch {
            cancel()
            throw error
        }
    }

    var audioLevel: Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        guard decibels.isFinite, decibels > -60 else { return 0 }
        return min(1, max(0, pow(10, decibels / 20)))
    }

    func stop() throws -> URL {
        guard let recorder, let url = audioURL else { throw VoicePromptError.recorderUnavailable }
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        audioURL = nil
        return url
    }

    func cancel() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let completedRecorder = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == completedRecorder else { return }
            if flag { self.onFinished?() } else { self.onInterrupted?() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let failedRecorder = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == failedRecorder else { return }
            self.onInterrupted?()
        }
    }
}
