import AVFoundation
import Foundation

/// Validate before handing the temporary recording to the system speech service.
/// Read in small buffers so transcription memory use stays bounded for long recordings.
enum VoiceAudioClip {
    static func open(_ url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 192_000,
              (1...2).contains(format.channelCount), duration.isFinite,
              duration >= 0.25,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw VoicePromptError.invalidClip
        }
        var hasSignal = false
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw VoicePromptError.invalidClip }
            for channel in 0..<Int(format.channelCount) {
                for sample in UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)) {
                    guard sample.isFinite else { throw VoicePromptError.invalidClip }
                    if abs(sample) > 0.0001 { hasSignal = true }
                }
            }
        }
        guard hasSignal else { throw VoicePromptError.noSpeech }
        file.framePosition = 0
        return file
    }
}
