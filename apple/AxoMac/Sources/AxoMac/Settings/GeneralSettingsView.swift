import AxoDaemonManager
import AxoRPC
import SwiftUI

struct GeneralSettingsView: View {
  var daemon: DaemonController
  let settingsClient: AxodSettingsClient?
  var ghostty: GhosttyRuntime
  var sleepPrevention: SleepPreventionController
  @State private var isConfirmingRestart = false

  private var scrollSensitivityPosition: Binding<Double> {
    Binding(
      get: { TerminalScrollSensitivity.sliderPosition(for: ghostty.scrollSensitivity) },
      set: {
        ghostty.setScrollSensitivity(
          TerminalScrollSensitivity.multiplier(atSliderPosition: $0)
        )
      }
    )
  }

  private var displayedScrollSensitivity: String {
    let value = TerminalScrollSensitivity.boundedMultiplier(ghostty.scrollSensitivity)
    return "\(value.formatted(.number.precision(.fractionLength(1))))×"
  }

  var body: some View {
    Form {
      Section("Terminal") {
        VStack(alignment: .leading, spacing: 8) {
          Slider(value: scrollSensitivityPosition, in: 0...1) {
            Text("Scroll sensitivity")
          }
          .accessibilityValue(Text(displayedScrollSensitivity))

          HStack {
            Text("0.1×")
            Spacer()
            Text("1.0×")
            Spacer()
            Text("3.0×")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      Section("Power") {
        Toggle(
          "Prevent sleep while Axo is running",
          isOn: Binding(
            get: { sleepPrevention.isEnabled },
            set: { sleepPrevention.setEnabled($0) }
          )
        )
        Text("Prevents idle system sleep. Manual sleep and closing the lid are unaffected.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      DaemonCommandSettingSection(setting: .shell, daemon: daemon, client: settingsClient)

      Section("axod") {
        LabeledContent("Daemon status", value: daemon.status.settingsTitle)

        switch daemon.status {
        case .disabled:
          Button("Enable axod") {
            daemon.enableDaemon()
          }
        case .requiresApproval:
          Button("Open Login Items Settings") {
            daemon.openLoginItemsSettings()
          }
          Button("Check Status") {
            daemon.startIfNeeded()
          }
        case .failed:
          Button("Retry daemon") {
            daemon.startIfNeeded()
          }
          Button("Restart axod…", role: .destructive) {
            isConfirmingRestart = true
          }
          .confirmationDialog(
            "Restart axod?", isPresented: $isConfirmingRestart, titleVisibility: .visible
          ) {
            Button("Restart axod", role: .destructive) { daemon.restartDaemon() }
          } message: {
            Text("Restarting stops every running shell and Pi process. Pi conversation histories are preserved.")
          }
          Button("Enable axod") {
            daemon.enableDaemon()
          }
        case .starting, .running, .updating:
          EmptyView()
        }
      }
    }
    .formStyle(.grouped)
  }
}
