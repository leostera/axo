import Foundation

/// Perceptual display scaling only; the recorder and transcription audio remain unchanged.
public enum VoiceWaveformScale {
    public static func heightFraction(for amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(min(1, amplitude))
        // Make quiet speech visible without normalizing silence/background noise to full height.
        // Match the recorder's -60 dB floor; reserve full height for -18 dB and louder.
        let normalized = min(1, max(0, (decibels + 60) / 42))
        return pow(normalized, 0.7)
    }
}
