import SwiftUI

struct CLICommandSettingsSection: View {
  var installation: CLICommandInstallation
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Section("Command Line") {
      HStack {
        LabeledContent("axo command", value: installation.isInstalling ? "Installing…" : installation.status.title)
        if installation.isInstalling { ProgressView().controlSize(.small) }
        if installation.status != .installed {
          Button("Install “axo” Command…") {
            Task { await installation.install() }
          }
          .disabled(installation.isInstalling || !installation.status.canInstall)
          .accessibilityIdentifier("install-axo-command")
        }
      }
      Text(installation.destination.path)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text(explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let failure = installation.failure {
        Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .onAppear { installation.refresh() }
    .onChange(of: scenePhase) { _, phase in if phase == .active { installation.refresh() } }
  }

  private var explanation: String {
    switch installation.status {
    case .missing:
      "Use axo from Terminal. Installs a link to this app; macOS may ask for administrator approval. Shell profiles are not changed."
    case .installed:
      "Run axo --help in Terminal. App updates also update the command. Your shell must include /usr/local/bin in PATH."
    case .conflict:
      "This location already contains a different file or link. It was not changed. Move it yourself before installing the command here."
    case .unavailable(let reason): reason
    }
  }
}
