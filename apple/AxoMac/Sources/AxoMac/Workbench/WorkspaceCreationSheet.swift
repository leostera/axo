import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceCreationSheet: View {
  var sessions: TerminalSessionsModel
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var directoryURL: URL?
  @State private var isChoosingDirectory = false
  @State private var isCreating = false
  @State private var directorySelectionError: String?

  private var normalizedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Workspace")
        .font(.title2.weight(.semibold))

      TextField("Workspace name", text: $name)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("workspace-name-field")

      VStack(alignment: .leading, spacing: 8) {
        Text("Directory")
          .font(.headline)
        HStack(spacing: 10) {
          Text(directoryURL?.path ?? "Choose a folder for this Workspace.")
            .font(.callout)
            .foregroundStyle(directoryURL == nil ? .secondary : .primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("Choose Directory…") {
            isChoosingDirectory = true
          }
          .accessibilityIdentifier("workspace-choose-directory-button")
        }
      }

      if let error = sessions.workspaceCreationError ?? directorySelectionError {
        VStack(alignment: .leading, spacing: 8) {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace-creation-form-error")
        }
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(isCreating ? "Creating…" : "Create Workspace") {
          createWorkspace()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isCreating || normalizedName.isEmpty || directoryURL == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
    .fileImporter(
      isPresented: $isChoosingDirectory,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        directoryURL = urls.first?.standardizedFileURL
        directorySelectionError = nil
      case .failure(let error):
        directorySelectionError = error.localizedDescription
      }
    }
    .onAppear {
      sessions.dismissWorkspaceCreationError()
    }
  }

  private func createWorkspace() {
    guard let directoryURL else { return }
    Task {
      isCreating = true
      let hasScopedAccess = directoryURL.startAccessingSecurityScopedResource()
      defer {
        if hasScopedAccess { directoryURL.stopAccessingSecurityScopedResource() }
        isCreating = false
      }
      let directoryBookmark = try? directoryURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      ).base64EncodedString()
      await sessions.createWorkspace(
        name: normalizedName,
        directoryPath: directoryURL.path,
        directoryBookmark: directoryBookmark
      )
      if sessions.workspaceCreationError == nil {
        dismiss()
      }
    }
  }
}
