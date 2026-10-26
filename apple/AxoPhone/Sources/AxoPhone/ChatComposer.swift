import SwiftUI

/// The message box. Typing into Pi from the phone is not wired up yet, so it says so and stays
/// closed rather than pretending.
struct ChatComposer: View {
  @Binding var draft: String
  let placeholder: String
  let canSend: Bool
  let send: () -> Void

  private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    HStack(alignment: .bottom, spacing: 6) {
      TextField(placeholder, text: $draft, axis: .vertical)
        .lineLimit(1...6)
        .padding(.leading, 18).padding(.vertical, 12)
        .frame(minHeight: 44)
        .disabled(!canSend)
        .submitLabel(.send)
        .onSubmit { if canSend && hasDraft { send() } }
      Button(action: send) {
        Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
          .foregroundStyle(canSend && hasDraft ? ChatColors.background : Color.secondary)
          .frame(width: 44, height: 44)
          .background(canSend && hasDraft ? Color.primary : ChatColors.disabledControl, in: Circle())
      }
      .accessibilityLabel("Send")
      .disabled(!(canSend && hasDraft))
      .padding(.bottom, 1)
    }
    .padding(.horizontal, 8).padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27))
    .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    .padding(.horizontal, 16)
  }
}
