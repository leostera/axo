import SwiftUI

/// Settings → Sessions: how the sidebar groups and orders Sessions. Changes apply at once.
struct SessionsSettingsView: View {
  var sessions: TerminalSessionsModel

  private func setting<Value>(_ keyPath: WritableKeyPath<SidebarGroupingSettings, Value>) -> Binding<Value> {
    Binding(
      get: { sessions.sidebarGrouping[keyPath: keyPath] },
      set: { value in
        var settings = sessions.sidebarGrouping
        settings[keyPath: keyPath] = value
        sessions.setSidebarGrouping(settings)
      })
  }

  var body: some View {
    Form {
      Section {
        Picker("Active for", selection: setting(\.activeWindowMinutes)) {
          ForEach(SidebarGroupingSettings.activeWindowChoices, id: \.self) { minutes in
            Text(minutes == 60 ? "1 hour" : "\(minutes) min").tag(minutes)
          }
        }
        .accessibilityIdentifier("sessions-active-window-picker")
        Toggle("Keep unseen Sessions in Active until seen", isOn: setting(\.unseenStayActive))
          .accessibilityIdentifier("sessions-unseen-stay-active-toggle")
        Picker("Move Sessions between groups every", selection: setting(\.regroupIntervalSeconds)) {
          ForEach(SidebarGroupingSettings.regroupIntervalChoices, id: \.self) { seconds in
            Text(seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min").tag(seconds)
          }
        }
        .accessibilityIdentifier("sessions-regroup-interval-picker")
      } header: {
        Text("Active")
      } footer: {
        Text(
          "A Session is Active while it's working or asking you, for a while after its last activity, and, if you keep them, while it has activity you haven't seen. Working out the groups only now and then means Sessions leave Active a few at a time."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Section("Order") {
        orderPicker("Pinned", \.pinnedOrder, choices: SidebarRowOrder.forPinned)
        orderPicker("Active", \.activeOrder, choices: SidebarRowOrder.forGroups)
        orderPicker("Earlier", \.earlierOrder, choices: SidebarRowOrder.forGroups)
      }

      Section("Look") {
        Picker("Mark unseen activity with", selection: setting(\.unseenMarker)) {
          ForEach(UnseenMarker.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("sessions-unseen-marker-picker")
        Toggle("Show group titles", isOn: setting(\.showsGroupTitles))
          .accessibilityIdentifier("sessions-group-titles-toggle")
      }

      Section {
        Button("Restore Defaults") { sessions.setSidebarGrouping(SidebarGroupingSettings()) }
          .disabled(sessions.sidebarGrouping == SidebarGroupingSettings())
      }
    }
    .formStyle(.grouped)
  }

  private func orderPicker(
    _ title: String, _ keyPath: WritableKeyPath<SidebarGroupingSettings, SidebarRowOrder>,
    choices: [SidebarRowOrder]
  ) -> some View {
    Picker(title, selection: setting(keyPath)) {
      ForEach(choices) { Text($0.title).tag($0) }
    }
    .accessibilityIdentifier("sessions-order-\(title.lowercased())-picker")
  }
}
