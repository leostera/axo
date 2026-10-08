import Foundation

/// Apple owns the asset download. Only label counts as bytes when NSProgress
/// explicitly declares file progress; generic work units are not megabytes.
enum AppleSpeechProgress {
    static func snapshot(_ progress: Progress) -> VoiceModelProgress {
        guard progress.totalUnitCount > 0 else {
            return .init(fraction: 0, detail: "Waiting for Apple's language assets…", stage: .checking)
        }
        let bytes = progress.kind == .file
            ? DownloadBytes(downloaded: progress.completedUnitCount, total: progress.totalUnitCount)
            : nil
        let finished = progress.isFinished
        return .init(
            fraction: progress.fractionCompleted,
            detail: finished ? "Finishing Apple speech setup…" : "Apple is downloading and installing English speech assets.",
            stage: finished ? .loading : .downloading,
            bytes: bytes
        )
    }
}
