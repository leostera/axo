import AxoDaemonManager
import AxoProtocol
import SwiftUI

struct AboutSettingsView: View {
  var daemon: DaemonController
  @State private var pointer: CGPoint?
  @State private var paneSize: CGSize = .zero

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  private var appCommit: String {
    Bundle.main.infoDictionary?["AXOGitCommit"] as? String ?? "Unknown"
  }

  private var daemonVersion: String {
    guard case .running(let version, _) = daemon.status else { return "Not available" }
    return version
  }

  private var daemonBuild: String {
    guard case .running(_, let buildNumber) = daemon.status else { return "Not available" }
    return buildNumber.description
  }

  private var daemonStatus: String {
    switch daemon.status {
    case .starting: "Starting…"
    case .running: "Running"
    case .updating: "Restarting…"
    case .requiresApproval: "Approval required"
    case .disabled: "Not enabled"
    case .failed(let message): "Unavailable — \(message)"
    }
  }

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 0)

      AboutMascotView(pointer: pointer, paneSize: paneSize)

      VStack(spacing: 6) {
        Text("Axo")
          .font(.system(size: 30, weight: .bold))
        Text("Agentic harness for terminal romantics")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 6) {
        aboutRow("Version", appVersion)
        aboutRow("Build", DaemonController.appBuildNumberLabel)
        aboutRow("Commit", appCommit)
        Divider()
          .frame(width: 240)
          .padding(.vertical, 3)
        aboutRow("axod version", daemonVersion)
        aboutRow("axod build", daemonBuild)
        aboutRow("Daemon status", daemonStatus)
      }
      .padding(.vertical, 4)

      HStack(spacing: 12) {
        Link("Docs", destination: URL(string: "https://github.com/leostera/axo#readme")!)
        Link("GitHub", destination: URL(string: "https://github.com/leostera/axo")!)
      }
      .buttonStyle(.bordered)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .coordinateSpace(name: AboutMascotView.space)
    .onContinuousHover(coordinateSpace: .named(AboutMascotView.space)) { phase in
      if case .active(let location) = phase { pointer = location } else { pointer = nil }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { paneSize = $0 }
  }

  private func aboutRow(_ title: String, _ value: String) -> some View {
    HStack(spacing: 10) {
      Text(title)
        .foregroundStyle(.secondary)
        .frame(width: 120, alignment: .trailing)
      Text(value)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(minWidth: 130, alignment: .leading)
    }
    .font(.callout)
  }
}
