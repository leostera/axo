import AxoDaemonManager
import AxoProtocol
import SwiftUI

/// Settings → Sessions → Limits: when Axod puts idle Pis to sleep (RFD0045). Both are Axod's
/// settings, loaded while it runs; a change is saved at once.
struct IdlePiLimitsSection: View {
  var daemon: DaemonController
  let client: AxodSettingsClient?
  @State private var minutes: Int?
  @State private var limit: Int?
  @State private var errorMessage: String?

  static let minuteChoices = [0, 10, 15, 30, 60, 120, 240, 480]
  static let limitChoices = [0, 5, 10, 20, 40, 80]

  var body: some View {
    Section {
      picker(
        "Put idle Pis to sleep after", value: $minutes, key: .idleMinutes,
        choices: Self.minuteChoices, label: Self.minutesLabel
      )
      .accessibilityIdentifier("sessions-idle-minutes-picker")
      picker(
        "Keep idle Pis awake, at most", value: $limit, key: .idleLimit,
        choices: Self.limitChoices, label: Self.limitLabel
      )
      .accessibilityIdentifier("sessions-idle-limit-picker")
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("sessions-idle-limits-error")
      }
    } header: {
      Text("Limits")
    } footer: {
      Text(
        minutes == nil
          ? "Start axod to view or change these limits."
          : "A Pi that isn't working or asking you anything is idle. Axod stops idle Pis to save memory, longest idle first, and the Session stays where it is: its Pi starts again when you show it, prompt it or type into it. Working Pis are never stopped."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .task(id: daemon.status) {
      guard daemon.status.isRunning else { return }
      await load()
    }
  }

  static func minutesLabel(_ minutes: Int) -> String {
    switch minutes {
    case 0: "Never"
    case let hours where hours % 60 == 0: hours == 60 ? "1 hour" : "\(hours / 60) hours"
    default: "\(minutes) min"
    }
  }

  static func limitLabel(_ limit: Int) -> String {
    limit == 0 ? "None" : "\(limit) Pis"
  }

  /// The choices, with the stored value among them even if it was set some other way.
  static func choices(_ choices: [Int], including value: Int?) -> [Int] {
    guard let value, !choices.contains(value) else { return choices }
    return (choices + [value]).sorted()
  }

  private func picker(
    _ title: String, value: Binding<Int?>, key: AxoConfigKey, choices: [Int],
    label: @escaping (Int) -> String
  ) -> some View {
    Picker(
      title,
      selection: Binding(
        get: { value.wrappedValue ?? -1 },
        set: { chosen in Task { await save(chosen, for: key, into: value) } })
    ) {
      if value.wrappedValue == nil { Text("—").tag(-1) }
      ForEach(Self.choices(choices, including: value.wrappedValue), id: \.self) {
        Text(label($0)).tag($0)
      }
    }
    .disabled(value.wrappedValue == nil)
  }

  private func load() async {
    guard let client else { return }
    do {
      minutes = Int(try await client.configValue(for: .idleMinutes).value)
      limit = Int(try await client.configValue(for: .idleLimit).value)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func save(_ chosen: Int, for key: AxoConfigKey, into value: Binding<Int?>) async {
    guard let client, chosen >= 0, chosen != value.wrappedValue else { return }
    do {
      value.wrappedValue = Int(try await client.setConfigValue(String(chosen), for: key).value)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
