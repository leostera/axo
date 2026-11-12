import AVFoundation
import AxoCompanion
import AxoPhoneModel
import Foundation

/// One engine per recording attempt, so cancellation from an older attempt cannot stop a new
/// microphone session. Speech is transcribed on the paired iPhone only after explicit Send.
@MainActor
final class WatchRecordingDictation: NSObject, DictationEngine, AVAudioRecorderDelegate {
  private let transcribe: @MainActor (URL) async throws -> String
  private var recorder: AVAudioRecorder?
  private var file: URL?
  private var interrupted: (@MainActor () -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var finishing = false

  init(transcribe: @escaping @MainActor (URL) async throws -> String) { self.transcribe = transcribe }

  var audioLevel: Double {
    guard let recorder, recorder.isRecording else { return 0 }
    recorder.updateMeters()
    let power = recorder.averagePower(forChannel: 0)
    guard power.isFinite else { return 0 }
    return min(1, max(0, pow(10, Double(power) / 20)))
  }

  func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
  func prepare(progress: @escaping @MainActor (VoiceSetupProgress) -> Void) async throws { try Task.checkCancellation() }

  func start(heard: @escaping @MainActor (HeardText) -> Void, interrupted: @escaping @MainActor () -> Void) async throws {
    try Task.checkCancellation()
    self.interrupted = interrupted
    let audio = AVAudioSession.sharedInstance()
    do {
      try audio.setCategory(.record, mode: .default)
      try audio.setActive(true)
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axo-watch-recordings", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent(UUID().uuidString + ".m4a")
      self.file = file
      let recorder = try AVAudioRecorder(url: file, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
      ])
      self.recorder = recorder
      recorder.delegate = self
      recorder.isMeteringEnabled = true
      guard recorder.prepareToRecord(), recorder.record(forDuration: CompanionVoiceRequest.maximumDuration) else {
        throw CompanionVoiceFailure.invalidAudio
      }
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
      observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
        object: nil, queue: .main) { [weak self] note in
          guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            type == AVAudioSession.InterruptionType.began.rawValue else { return }
          Task { @MainActor in self?.interrupted?() }
        })
    } catch {
      await cancel()
      throw CompanionVoiceFailure.invalidAudio
    }
  }

  func finish() async throws -> String {
    guard let file, recorder != nil else { throw CompanionVoiceFailure.invalidAudio }
    finishing = true
    stopMicrophone()
    defer { discardFile() }
    return try await transcribe(file)
  }

  func cancel() async {
    finishing = true
    stopMicrophone()
    discardFile()
  }

  private func stopMicrophone() {
    interrupted = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    recorder?.delegate = nil
    recorder?.stop()
    recorder = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func discardFile() {
    if let file { try? FileManager.default.removeItem(at: file) }
    file = nil
  }

  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    Task { @MainActor in if !self.finishing { self.interrupted?() } }
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    Task { @MainActor in if !self.finishing { self.interrupted?() } }
  }
}
