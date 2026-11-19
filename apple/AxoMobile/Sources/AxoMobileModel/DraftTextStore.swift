import Foundation

/// Local composition only: never an outbox and never authority to send restored text.
@MainActor
public final class DraftTextStore {
  public struct Text: Codable, Equatable {
    public let destination: PhoneWorkbench.Selection
    public let text: String
    public init(destination: PhoneWorkbench.Selection, text: String) {
      self.destination = destination
      self.text = text
    }
  }

  public struct Checkpoint: Codable, Equatable {
    public let id: UUID
    public let destination: PhoneWorkbench.Selection
    public let text: String
  }

  private struct Archive: Codable {
    var version = 1
    var texts: [Text] = []
    var voice: Checkpoint?
  }

  private let url: URL
  private var archive = Archive()
  private var readable = true
  public private(set) var failure: String?

  public init(url: URL) {
    self.url = url
    do {
      let data = try Data(contentsOf: url)
      let loaded = try JSONDecoder().decode(Archive.self, from: data)
      guard loaded.version == 1, Set(loaded.texts.map(\.destination)).count == loaded.texts.count else {
        throw CocoaError(.coderReadCorrupt)
      }
      archive = loaded
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // First launch: there is no prior composition to restore.
    } catch {
      readable = false
      failure = "Saved drafts could not be read. Existing saved data has been left untouched."
    }
  }

  public static func location(accountID: UUID) -> URL {
    URL.applicationSupportDirectory.appending(path: "Drafts", directoryHint: .isDirectory)
      .appending(path: accountID.uuidString.lowercased() + ".json")
  }

  /// Merge a crash/interruption checkpoint once, without restoring microphone or Send intent.
  public func restoredTexts() -> [Text] {
    var texts = Dictionary(uniqueKeysWithValues: archive.texts.map { ($0.destination, $0.text) })
    if let voice = archive.voice {
      texts[voice.destination] = VoiceTranscript(text: voice.text, delivery: .draft)
        .appending(to: texts[voice.destination] ?? "")
    }
    return texts.map { Text(destination: $0.key, text: $0.value) }
  }

  public func save(texts: [Text], voice: Checkpoint?) {
    guard readable else { return }
    let next = Archive(texts: texts, voice: voice)
    do {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var excluded = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try excluded.setResourceValues(values)
      var options: Data.WritingOptions = [.atomic]
      #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
      #endif
      try JSONEncoder().encode(next).write(to: url, options: options)
      archive = next
      failure = nil
    } catch {
      failure = "Drafts are kept in this app, but could not be saved on this device. Keep Axo open until saving is available."
    }
  }
}
