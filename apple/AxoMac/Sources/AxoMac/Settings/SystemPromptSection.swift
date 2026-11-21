import Foundation
import SwiftUI

/// Settings and a text editor edit the same host-local Markdown file.
struct SystemPromptSection: View {
  private let file = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".axo/agent/SYSTEM_PROMPT.md")
  @State private var saved: String?
  @State private var draft = ""
  @State private var problem: String?

  var body: some View {
    Section("System Prompt") {
      Text("Add instructions for agents on this Mac. Leave blank to use Axo’s built-in guidance alone.")
        .foregroundStyle(.secondary)
      TextEditor(text: $draft)
        .font(.system(.body, design: .monospaced))
        .frame(minHeight: 100)
        .accessibilityLabel("System Prompt")
      Text("~/.axo/agent/SYSTEM_PROMPT.md").font(.caption.monospaced()).textSelection(.enabled)
      if let problem { Text(problem).foregroundStyle(.secondary) }
      HStack {
        Button("Reload from File", action: load)
        Spacer()
        Button("Save", action: save).disabled(saved == nil || draft == saved)
      }
    }.onAppear { if saved == nil { load() } }
  }

  private func readFile() throws -> String {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536
      else { throw CocoaError(.fileReadTooLarge) }
      return try String(contentsOf: file, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      return ""
    }
  }

  private func load() {
    do { let text = try readFile(); draft = text; saved = text; problem = nil }
    catch { problem = error.localizedDescription }
  }

  private func save() {
    do {
      guard draft.utf8.count <= 65_536 else { problem = "Keep the prompt under 64 KiB."; return }
      guard try readFile() == saved else {
        problem = "The file changed outside Axo. Copy your edits before reloading."; return
      }
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try draft.write(to: file, atomically: true, encoding: .utf8)
      saved = draft; problem = nil
    } catch { problem = error.localizedDescription }
  }
}
