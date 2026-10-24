import AppKit
import AxoDaemonManager
import AxoRPC
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
  case agent
  case remoteAccess
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .agent: "Agent"
    case .remoteAccess: "Remote Access"
    case .about: "About"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintbrush"
    case .agent: "terminal"
    case .remoteAccess: "network"
    case .about: "info.circle"
    }
  }
}

struct SettingsView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  var sleepPrevention: SleepPreventionController
  let ghostty: GhosttyRuntime
  let settingsClient: AxodSettingsClient?
  var remoteAccess: RemoteAccessModel
  @Binding var selection: SettingsSection
  @Binding var appearanceTheme: AppearanceTheme
  @Bindable var pairingLink: PairingLinkRouter

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
          GeneralSettingsView(
            daemon: daemon,
            settingsClient: settingsClient,
            ghostty: ghostty,
            sleepPrevention: sleepPrevention
          )
        case .appearance:
          AppearanceSettingsView(theme: $appearanceTheme)
        case .agent:
          AgentSettingsView(daemon: daemon, sessions: sessions, settingsClient: settingsClient)
        case .remoteAccess:
          RemoteAccessSettingsView(
            daemon: daemon, remoteAccess: remoteAccess, pairingCode: $pairingLink.pendingCode)
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

private struct AgentSettingsView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  let settingsClient: AxodSettingsClient?

  var body: some View {
    Form {
      Section("Recovery") {
        Toggle(
          "Automatically restart unavailable Pi sessions",
          isOn: Binding(
            get: { sessions.automaticallyRestartUnavailablePi },
            set: { sessions.setAutomaticPiRestartEnabled($0) }
          )
        )
        .accessibilityIdentifier("auto-restart-unavailable-pi-toggle")

        Text(
          "Axo retries recovery only when Pi reports it is idle or its transcript is unowned. It never force-stops a Pi automatically; if the state is uncertain, Restart Pi remains available."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      DaemonCommandSettingSection(setting: .agent, daemon: daemon, client: settingsClient)
    }
    .formStyle(.grouped)
  }
}
