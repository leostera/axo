import AxoProtocol
import SwiftUI

enum SidebarRenameTarget: Identifiable {
  case session(TerminalSession)
  case workspace(WorkspaceRecord)

  enum ID: Hashable {
    case session(SessionID)
    case workspace(String)
  }

  var id: ID {
    switch self {
    case .session(let session): .session(session.id)
    case .workspace(let workspace): .workspace(workspace.workspaceId)
    }
  }

  var name: String {
    switch self {
    case .session(let session): session.displayName
    case .workspace(let workspace): workspace.name
    }
  }
}

struct SidebarInlineRenameEditor: View {
  @Binding var text: String
  let identifier: String
  let onSave: () -> Void
  let onCancel: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField("Name", text: $text)
        .textFieldStyle(.plain)
        .lineLimit(1)
        .focused($isFocused)
        .onSubmit(onSave)
        .onExitCommand(perform: onCancel)
        .accessibilityIdentifier(identifier)

      Button(action: onSave) {
        Image(systemName: "checkmark")
      }
      .buttonStyle(.plain)
      .help("Save name")
      .accessibilityLabel("Save name")
      .accessibilityIdentifier("inline-rename-save")

      Button(action: onCancel) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Cancel rename")
      .accessibilityLabel("Cancel rename")
      .accessibilityIdentifier("inline-rename-cancel")
    }
    .onAppear { isFocused = true }
  }
}
