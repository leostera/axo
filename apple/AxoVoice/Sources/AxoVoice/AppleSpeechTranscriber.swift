import AVFoundation
import Foundation
import Speech

public enum AppleSpeechProvider {
    public static func makeTranscriber() -> any LocalSpeechTranscribing {
        if #available(iOS 26, macOS 26, *) { return AppleSpeechTranscriber() }
        return UnavailableAppleSpeech()
    }
}

public enum AppleSpeechError: LocalizedError {
    case requiresNewerOS, unavailable, unsupportedLocale, assetsNotReady, notPrepared

    public var errorDescription: String? {
        switch self {
        case .requiresNewerOS: "Apple on-device voice requires iOS 26 or later. You can still type or use keyboard dictation."
        case .unavailable: "Apple on-device speech is not available on this device. No audio was uploaded."
        case .unsupportedLocale: "Apple's English speech model is not supported on this device."
        case .assetsNotReady: "Apple's speech assets are not ready. Connect to Wi-Fi and try preparing voice again."
        case .notPrepared: "Prepare Apple on-device speech before recording."
        }
    }
}

private actor UnavailableAppleSpeech: LocalSpeechTranscribing {
    func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws { throw AppleSpeechError.requiresNewerOS }
    func transcribe(_ audioURL: URL) async throws -> String { throw AppleSpeechError.requiresNewerOS }
    func unload() async {}
}

/// SpeechTranscriber is the on-device SpeechAnalyzer module. There is deliberately
/// no SFSpeechRecognizer/server fallback and no external model/runtime dependency.
@available(iOS 26, macOS 26, *)
public actor AppleSpeechTranscriber: LocalSpeechTranscribing {
    private var locale: Locale?
    private var activeAnalyzer: SpeechAnalyzer?

    public init() {}

    public func prepare(progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws {
        guard locale == nil else { return }
        guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.unavailable }
        progress(.init(fraction: 0, detail: "Checking Apple's English speech assets", stage: .checking))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw AppleSpeechError.unsupportedLocale
        }
        try Task.checkCancellation()
        // Retain only this app's English reservation, not every locale on the device.
        try await AssetInventory.reserve(locale: locale)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await install(request, progress: progress)
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw AppleSpeechError.assetsNotReady }
        self.locale = locale
        progress(.init(fraction: 1, detail: "Apple on-device speech is ready", stage: .loading))
    }

    private func install(_ request: AssetInstallationRequest, progress: @escaping @Sendable (VoiceModelProgress) -> Void) async throws {
        let reporter = Task {
            while !Task.isCancelled {
                progress(AppleSpeechProgress.snapshot(request.progress))
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
            try Task.checkCancellation()
        } onCancel: {
            request.progress.cancel()
        }
    }

    public func transcribe(_ audioURL: URL) async throws -> String {
        guard let locale else { throw AppleSpeechError.notPrepared }
        try Task.checkCancellation()
        let file = try VoiceAudioClip.open(audioURL)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        activeAnalyzer = analyzer
        defer { activeAnalyzer = nil }

        return try await withTaskCancellationHandler {
            let results = Task {
                var transcript = AttributedString()
                for try await result in module.results {
                    try Task.checkCancellation()
                    if result.isFinal { transcript.append(result.text) }
                }
                return String(transcript.characters)
            }
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let text = try await results.value
                try Task.checkCancellation()
                return text
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await results.value
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    public func unload() async {
        await activeAnalyzer?.cancelAndFinishNow()
        activeAnalyzer = nil
        locale = nil
        // Asset reservations persist across launches; Apple manages the shared disk cache.
    }
}
