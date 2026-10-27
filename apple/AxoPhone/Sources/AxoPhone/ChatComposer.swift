import SwiftUI

/// The message box. It stays closed, saying why in its placeholder, when there is nobody to send
/// to. Once a message runs past a couple of lines it can be opened full screen, as the original
/// app did.
struct ChatComposer: View {
  @Binding var draft: String
  let placeholder: String
  let canSend: Bool
  let send: () -> Void

  @State private var editorHeight: CGFloat = 0
  @State private var showingExpandedEditor = false

  private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// Taller than about two lines of body text.
  private var isLong: Bool { editorHeight > 64 }

  var body: some View {
    HStack(alignment: .bottom, spacing: 6) {
      TextField(placeholder, text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .padding(.leading, 18).padding(.vertical, 12)
        .frame(minHeight: 44)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = $0 }
        .disabled(!canSend)
        .accessibilityIdentifier("composer")
        .submitLabel(.send)
        .onSubmit { if canSend && hasDraft { send() } }
      if isLong {
        Button { showingExpandedEditor = true } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 40)
            .background(.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand message editor")
        .padding(.bottom, 3)
      }
      Button(action: send) {
        Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
          .foregroundStyle(canSend && hasDraft ? ChatColors.background : Color.secondary)
          .frame(width: 44, height: 44)
          .background(canSend && hasDraft ? Color.primary : ChatColors.disabledControl, in: Circle())
      }
      .accessibilityLabel("Send")
      .accessibilityIdentifier("send-message")
      .disabled(!(canSend && hasDraft))
      .padding(.bottom, 1)
    }
    .padding(.horizontal, 8).padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
    .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    .padding(.horizontal, 16)
    .fullScreenCover(isPresented: $showingExpandedEditor) {
      ExpandedComposerEditor(draft: $draft, placeholder: placeholder)
    }
  }
}

/// The whole screen for a long message; Done returns to the conversation with it in the box.
private struct ExpandedComposerEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var draft: String
  let placeholder: String
  @FocusState private var isFocused: Bool

  var body: some View {
    NavigationStack {
      TextEditor(text: $draft)
        .font(.body)
        .focused($isFocused)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .topLeading) {
          if draft.isEmpty {
            Text(placeholder)
              .foregroundStyle(.secondary)
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .padding(.horizontal, 12)
        .background(ChatColors.background)
        .accessibilityLabel("Expanded message")
        .navigationTitle(placeholder)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
    }
    .task { isFocused = true }
  }
}
