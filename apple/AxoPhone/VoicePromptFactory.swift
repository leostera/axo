import AxoVoice
import Foundation

@MainActor
enum VoicePromptFactory {
    static func make() -> VoicePrompt {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--axo-voice-preview") {
            let delay: Duration = ProcessInfo.processInfo.arguments.contains("--axo-voice-preview-fast") ? .milliseconds(150) : .seconds(30)
            return VoicePrompt(recorder: PreviewRecorder(), transcriber: PreviewTranscriber(delay: delay))
        }
        #endif
        return VoicePrompt(recorder: MicrophoneRecorder(), transcriber: AppleSpeechProvider.makeTranscriber())
    }
}

#if DEBUG
/// No microphone, model download, relay, or user audio in UI regression tests.
@MainActor
private final class PreviewRecorder: VoiceRecording {
    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?
    private var source: URL?
    func requestPermission() async -> Bool { true }
    func start() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-voice-\(UUID()).wav")
        try Data([0, 1]).write(to: url)
        source = url
    }
    func stop() throws -> URL {
        guard let source else { throw VoicePromptError.recorderUnavailable }
        self.source = nil
        return source
    }
    func cancel() {
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
    }
}

private actor PreviewTranscriber: LocalSpeechTranscribing {
    let delay: Duration
    init(delay: Duration) { self.delay = delay }

    func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws {
        progress(.init(fraction: 1, detail: "Synthetic voice fixture ready"))
    }
    func transcribe(_ audioURL: URL) async throws -> String {
        try await Task.sleep(for: delay)
        return "Synthetic dictated prompt"
    }
    func unload() async {}
}
#endif
