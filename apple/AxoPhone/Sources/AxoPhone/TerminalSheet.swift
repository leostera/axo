import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// A Session's terminal as text, with the keys a phone keyboard lacks. A real terminal view will
/// replace this; until then it reads shells and does not draw full-screen programs.
struct TerminalSheet: View {
  let model: HostWorkbenchModel
  @Environment(\.dismiss) private var dismiss
  @State private var line = ""

  private var text: String {
    model.focusedShell.flatMap { model.transcripts[$0]?.text } ?? ""
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            Text(text.isEmpty ? "Waiting for output…" : text)
              .font(.system(.footnote, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(12)
              .textSelection(.enabled)
            Color.clear.frame(height: 1).id("end")
          }
          .onChange(of: text) { proxy.scrollTo("end") }
        }
        Divider()
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            key("esc", "\u{1B}")
            key("tab", "\t")
            key("ctrl-c", "\u{03}")
            key("↑", "\u{1B}[A")
            key("↓", "\u{1B}[B")
            key("←", "\u{1B}[D")
            key("→", "\u{1B}[C")
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
        }
        HStack {
          TextField("command", text: $line)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .onSubmit(submit)
          Button("Send", action: submit).disabled(model.focusedShell == nil)
        }
        .padding(12)
      }
      .background(ChatColors.background)
      .navigationTitle("Terminal")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func key(_ title: String, _ bytes: String) -> some View {
    Button(title) { Task { await model.send(bytes) } }
      .buttonStyle(.bordered)
      .disabled(model.focusedShell == nil)
  }

  private func submit() {
    let typed = line + "\r"
    line = ""
    Task { await model.send(typed) }
  }
}
