import SwiftUI

struct AppUpdateSettingsSection: View {
  var automatic: AppAutomaticUpdates
  var canCheck = true
  var setEnabled: (Bool) -> Void
  var check: () -> Void

  var body: some View {
    Section("Updates") {
      Toggle("Automatically install updates", isOn: Binding(
        get: { automatic.isEnabled }, set: setEnabled))
        .accessibilityIdentifier("automatic-updates")
      VStack(alignment: .leading, spacing: 4) {
        Text("Checks every minute while Axo is running and awake, then installs verified releases and restarts automatically. Updates may restart terminals and Pi processes, interrupting active work.")
        Text("Skipped releases and reminders are respected. Failed downloads retry after 15 minutes.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      if let failure = automatic.failure {
        Text(failure).font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("automatic-update-failure")
      }
      Button("Check for Updates…", action: check)
        .disabled(!canCheck)
    }
  }
}
