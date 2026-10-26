import AxoClient
import AxoPhoneModel
import AxoProtocol
import SwiftUI

/// One Mac: its Sessions in a list, and the selected Session's terminal.
struct HostWorkbenchView: View {
  @State private var model: HostWorkbenchModel
  @State private var showingSessions = false

  init(host: RemoteHost, environment: AppEnvironment) {
    let connection = HostConnection(
      endpoint: environment.endpoint, host: host.reference, tokens: environment.account.tokens)
    _model = State(
      initialValue: HostWorkbenchModel(host: host, connection: connection, account: environment.account))
  }

  var body: some View {
    VStack(spacing: 0) {
      if model.status == .offline {
        Label("\(model.hostLabel) is offline", systemImage: "wifi.slash")
          .frame(maxWidth: .infinity).padding(8).background(.orange.opacity(0.2))
      }
      if let failure = model.failure {
        Text(failure).font(.caption).foregroundStyle(.red).padding(6)
      }
      TerminalTextView(model: model)
    }
    .navigationTitle(model.selectedSession?.displayName ?? model.hostLabel)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Button("Sessions", systemImage: "sidebar.leading") { showingSessions = true }
    }
    .sheet(isPresented: $showingSessions) { SessionsSheet(model: model) }
    .task {
      await model.start()
    }
    .onDisappear { model.stop() }
  }
}

private struct SessionsSheet: View {
  let model: HostWorkbenchModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.sessions, id: \.sessionId) { session in
          Button {
            model.selectedSessionID = session.sessionId
            dismiss()
          } label: {
            HStack {
              Text(session.emoji ?? "").frame(width: 28)
              VStack(alignment: .leading) {
                Text(session.displayName)
                if let workspace = session.workspaceName {
                  Text(workspace).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if session.sessionId == model.selectedSessionID { Image(systemName: "checkmark") }
            }
          }
          .swipeActions {
            Button("Close", role: .destructive) { Task { await model.closeSession(session.sessionId) } }
          }
        }
      }
      .navigationTitle("Sessions")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("New", systemImage: "plus") {
            Task {
              await model.createSession()
              dismiss()
            }
          }
          .disabled(model.status != .online)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

/// The terminal as text, with the keys a phone keyboard lacks. A real terminal view replaces
/// this; until then it reads shells and does not draw full-screen programs.
private struct TerminalTextView: View {
  let model: HostWorkbenchModel
  @State private var line = ""

  private var text: String {
    model.focusedShell.flatMap { model.transcripts[$0]?.text } ?? ""
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          Text(text.isEmpty ? "Waiting for output…" : text)
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
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
        .padding(.horizontal, 8)
      }
      HStack {
        TextField("command", text: $line)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
          .onSubmit(submit)
        Button("Send", action: submit).disabled(model.focusedShell == nil)
      }
      .padding(8)
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
