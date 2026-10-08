import AVFoundation
import AxoVoice
import Foundation

@MainActor
final class MicrophoneRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    var onFinished: (() -> Void)?
    var onInterrupted: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.interruptIfRecording() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.interruptIfRecording() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func start() throws {
        cancel()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            sessionActive = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("axo-voice-\(UUID().uuidString).wav")
            audioURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.prepareToRecord() else { throw VoicePromptError.recorderUnavailable }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            guard recorder.record() else { throw VoicePromptError.recorderUnavailable }
        } catch {
            cancel()
            throw error
        }
    }

    func stop() throws -> URL {
        guard let recorder, let url = audioURL else { throw VoicePromptError.recorderUnavailable }
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        audioURL = nil
        deactivateSession()
        return url
    }

    func cancel() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        deactivateSession()
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func interruptIfRecording() {
        guard recorder != nil else { return }
        onInterrupted?()
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
