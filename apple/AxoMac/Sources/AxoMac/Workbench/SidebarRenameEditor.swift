import AxoProtocol
import SwiftUI

enum SidebarRenameTarget: Identifiable {
  case session(TerminalSession)

  enum ID: Hashable {
    case session(SessionID)
  }

  var id: ID {
    switch self {
    case .session(let session): .session(session.id)
    }
  }

  var name: String {
    switch self {
    case .session(let session): session.displayName
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
