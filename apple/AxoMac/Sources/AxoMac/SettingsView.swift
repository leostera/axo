import AppKit
import AxoDaemonManager
import SwiftUI

enum AppearanceTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case general
  case appearance
  case remoteAccess
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .remoteAccess: "Remote Access"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .remoteAccess: "network"
    case .about: "info.circle"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var daemon: DaemonController
  let ghostty: GhosttyRuntime
  @Binding var selection: SettingsSection
  @Binding var appearanceTheme: AppearanceTheme
  @ObservedObject var pairingLink: PairingLinkRouter

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
          GeneralSettingsView(daemon: daemon, ghostty: ghostty)
        case .appearance:
          AppearanceSettingsView(theme: $appearanceTheme)
        case .remoteAccess:
          RemoteAccessSettingsView(daemon: daemon, pairingCode: $pairingLink.pendingCode)
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

private struct AppearanceSettingsView: View {
  @Binding var theme: AppearanceTheme

  var body: some View {
    Form {
      Picker("Theme", selection: $theme) {
        ForEach(AppearanceTheme.allCases) { theme in
          Text(theme.title).tag(theme)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("appearance-theme-picker")
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var daemon: DaemonController
  @ObservedObject var ghostty: GhosttyRuntime

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

private struct AboutSettingsView: View {
  @ObservedObject var daemon: DaemonController

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

      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)

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
