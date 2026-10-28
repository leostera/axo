import AxoPhoneModel
import SwiftUI

/// The message box. It stays closed, saying why in its placeholder, when there is nobody to send
/// to. Once a message runs past a couple of lines it can be opened full screen, as the original
/// app did. With `voice`, a message can be said instead of typed: while listening the box
/// becomes the listening bar.
struct ChatComposer: View {
  @Binding var draft: String
  let placeholder: String
  let canSend: Bool
  let voice: VoicePrompt?
  let send: () -> Void

  @State private var editorHeight: CGFloat = 0
  @State private var showingExpandedEditor = false

  private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// Tall enough (about three lines) for the expand button to sit above Send inside the box: the
  /// button, the spacing and Send.
  private var isLong: Bool { editorHeight >= Self.expandSize + Self.expandSpacing + 44 }
  private static let expandSize: CGFloat = 40
  private static let expandSpacing: CGFloat = 6

  private var isListening: Bool {
    guard let voice else { return false }
    return voice.isListening || voice.state == .finishing
  }

  private var showsVoiceStatus: Bool {
    switch voice?.state {
    case .preparing, .failed: true
    default: false
    }
  }

  var body: some View {
    let _ = RenderCount.note("Composer")
    VStack(spacing: 10) {
      if let voice { VoiceStatusCard(voice: voice) }
      if let voice, isListening {
        VoiceListeningBar(voice: voice, canSend: canSend)
      } else {
        box
      }
    }
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isListening)
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showsVoiceStatus)
  }

  private var box: some View {
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
      // An empty box offers the microphone where Send goes; once something is typed, Send (the
      // keyboard has its own dictation for adding to what is typed).
      if let voice, !hasDraft {
        VoiceButton(voice: voice, enabled: canSend)
      } else {
        sendButton
          // Drawn above Send rather than beside the text, so the text never narrows and re-wraps
          // as it appears, and the box's layout is the same with it or without.
          .overlay(alignment: .top) {
            if isLong {
              expandButton.offset(y: -(Self.expandSize + Self.expandSpacing))
            }
          }
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
    .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    .padding(.horizontal, 16)
    .fullScreenCover(isPresented: $showingExpandedEditor) {
      ExpandedComposerEditor(draft: $draft, placeholder: placeholder)
    }
  }

  private var expandButton: some View {
    Button { showingExpandedEditor = true } label: {
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .font(.system(size: 16, weight: .medium))
        .frame(width: Self.expandSize, height: Self.expandSize)
        .background(.secondary.opacity(0.12), in: Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Expand message editor")
  }

  private var sendButton: some View {
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
