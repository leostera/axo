import AxoClient
import SwiftUI

/// One confirmation, including retries. A retry of an uncertain reply keeps the same request ID
/// and payload. Only a definitive folder rejection lets the person change the destination path.
public struct SessionForkSheet: View {
  let machine: String
  let fork: @MainActor (UUID, String?) async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var requestID = UUID()
  @State private var folder = ""
  @State private var submittedFolder: String?
  @State private var needsFolder = false
  @State private var inFlight = false
  @State private var failure: String?

  public init(machine: String, fork: @escaping @MainActor (UUID, String?) async throws -> Void) {
    self.machine = machine
    self.fork = fork
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Fork this session to \(machine)?")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text("Copies chat history, not project files. The original session stays here.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if needsFolder {
        Text("Choose a destination folder")
          .font(.subheadline.weight(.semibold))
        Text("Enter the absolute path to an existing folder on \(machine).")
          .foregroundStyle(.secondary)
        TextField("/absolute/path", text: $folder)
          .textFieldStyle(.roundedBorder)
          #if os(iOS)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          #endif
          .accessibilityLabel("Destination folder on \(machine)")
          .accessibilityIdentifier("session-fork-folder")
          .disabled(inFlight)
      } else if let submittedFolder {
        Text("Destination folder: \(submittedFolder)")
          .foregroundStyle(.secondary)
      }
      if let failure {
        Text(failure).foregroundStyle(.red)
      }
      HStack {
        if inFlight { ProgressView().controlSize(.small).accessibilityLabel("Forking session") }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(inFlight)
        Button(failure == nil ? "Fork" : "Retry Fork", action: submit)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(inFlight || (needsFolder && !trimmedFolder.hasPrefix("/")))
          .accessibilityIdentifier("session-fork-confirm")
      }
    }
    .padding(24)
    #if os(macOS)
    .frame(width: 440)
    #else
    .frame(idealWidth: 320, maxWidth: 360)
    .fixedSize(horizontal: false, vertical: true)
    #endif
    .interactiveDismissDisabled(inFlight)
  }

  private var trimmedFolder: String { folder.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func submit() {
    guard !inFlight else { return }
    if needsFolder {
      guard trimmedFolder.hasPrefix("/") else { return }
      if submittedFolder != trimmedFolder { requestID = UUID() }
      submittedFolder = trimmedFolder
    }
    inFlight = true
    failure = nil
    Task {
      defer { inFlight = false }
      do {
        try await fork(requestID, submittedFolder)
        dismiss()
      } catch {
        needsFolder = SessionForkError.needsDestinationFolder(error)
        if !needsFolder { failure = error.localizedDescription }
      }
    }
  }
}
