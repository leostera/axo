import AppKit
import AxoDaemonManager
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .about: "info.circle"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var daemon: DaemonController
  @Binding var selection: SettingsSection

  private var sidebarSelection: Binding<SettingsSection?> {
    Binding(
      get: { selection },
      set: { if let section = $0 { selection = section } }
    )
  }

  var body: some View {
    HStack(spacing: 0) {
      List(SettingsSection.allCases, selection: sidebarSelection) { section in
        Label(section.title, systemImage: section.systemImage)
          .tag(section)
      }
      .listStyle(.sidebar)
      .frame(width: 180)

      Divider()

      Group {
        switch selection {
        case .general:
          GeneralSettingsView(daemon: daemon)
        case .about:
          AboutSettingsView(daemon: daemon)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(20)
    }
    .frame(minWidth: 700, minHeight: 440)
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var daemon: DaemonController
  @AppStorage("terminalScrollSensitivity") private var scrollSensitivity =
    TerminalScrollSensitivity.defaultMultiplier

  private var scrollSensitivityPosition: Binding<Double> {
    Binding(
      get: { TerminalScrollSensitivity.sliderPosition(for: scrollSensitivity) },
      set: { scrollSensitivity = TerminalScrollSensitivity.multiplier(atSliderPosition: $0) }
    )
  }

  private var displayedScrollSensitivity: String {
    let value = TerminalScrollSensitivity.boundedMultiplier(scrollSensitivity)
    return "\(value.formatted(.number.precision(.fractionLength(1))))×"
  }

  var body: some View {
    Form {
      Section("Terminal") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Scroll sensitivity")
            Spacer()
            Text(displayedScrollSensitivity)
              .monospacedDigit()
          }

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

          Text("1.0× keeps Axo’s current scroll feel.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Axo D") {
        LabeledContent("Daemon status", value: daemon.status.settingsTitle)

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
  }
}

private struct AboutSettingsView: View {
  @ObservedObject var daemon: DaemonController

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
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
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 16) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .scaledToFit()
          .frame(width: 64, height: 64)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 5) {
          Text("Axo")
            .font(.title2.bold())
          Text("Version \(appVersion) (\(DaemonController.appBuildNumberLabel))")
            .foregroundStyle(.secondary)
        }
      }

      Form {
        Section("Components") {
          LabeledContent("Axo D version", value: daemonVersion)
          LabeledContent("Axo D build", value: daemonBuild)
          LabeledContent("Daemon status", value: daemonStatus)
        }
      }
      .formStyle(.grouped)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}
