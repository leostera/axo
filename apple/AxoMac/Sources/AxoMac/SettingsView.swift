import AxoDaemonManager
import SwiftUI

struct SettingsView: View {
  @ObservedObject var daemon: DaemonController

  var body: some View {
    Form {
      Section("Axo") {
        LabeledContent("App build", value: DaemonController.appBuildNumberLabel)
        LabeledContent("Axo D", value: daemon.status.settingsTitle)

        switch daemon.status {
        case .disabled:
          Button("Enable Axo D") {
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
          Button("Enable Axo D") {
            daemon.enableDaemon()
          }
        case .starting, .running, .updating:
          EmptyView()
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 360)
    .padding()
  }
}
