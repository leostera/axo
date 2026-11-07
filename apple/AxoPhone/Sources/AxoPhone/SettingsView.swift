import AxoPhoneModel
import SwiftUI

struct SettingsView: View {
  let account: AccountSession
  /// What the account's Sessions can use: Settings › Apps.
  let apps: AppsModel
  /// How the chat list groups chats, and the pins: kept on this phone.
  let chatList: ChatListPreferences
  /// The page Settings opens on.
  var opening: Opening = .settings
  let signOut: () -> Void
  @Environment(\.dismiss) private var dismiss
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white
  @State private var path = NavigationPath()

  /// The page Settings opens on: its first, or Apps (as the account panel's Apps row opens it).
  enum Opening: String, Identifiable {
    case settings, apps
    var id: String { rawValue }
  }

  private enum SettingsPage: Hashable { case apps }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          NavigationLink(value: SettingsPage.apps) {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Apps")
                Text("Gmail, GitHub, MCP servers and more").font(.caption).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "powerplug")
            }
          }
          .accessibilityIdentifier("settings-apps")
        } footer: {
          Text("What your Sessions can use, the accounts they use it with, and what they did.")
        }

        ChatListSettingsSection(preferences: chatList)

        Section("Theme") {
          Picker(selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
          } label: {
            Label("Appearance", systemImage: "moon")
          }
          .pickerStyle(.menu)

          Picker(selection: $accentColor) {
            ForEach(AppAccentColor.allCases) { option in
              HStack(spacing: 8) {
                Circle().fill(option.color).frame(width: 12, height: 12)
                Text(option.title)
              }
              .tag(option)
            }
          } label: {
            Label("Accent color", systemImage: "paintpalette")
          }
          .pickerStyle(.menu)
        }

        Section {
          Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
            dismiss()
            signOut()
          }
        } footer: {
          Text("Signing out ends this phone's session. Your Macs and conversations stay on your account.")
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(ChatColors.background)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: SettingsPage.self) { _ in AppsView(model: apps) }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(.secondary.opacity(0.12), in: Circle())
          }
          .accessibilityLabel("Close settings")
        }
      }
    }
    .onAppear { if opening == .apps, path.isEmpty { path.append(SettingsPage.apps) } }
    .presentationDetents([.large])
    .presentationBackground(ChatColors.background)
    .tint(accentColor.color)
  }
}

/// Settings › Chats: how the list groups chats, as the Mac's Settings › Sessions sets it.
private struct ChatListSettingsSection: View {
  @Bindable var preferences: ChatListPreferences

  var body: some View {
    Section {
      Picker(selection: $preferences.settings.activeWindowMinutes) {
        ForEach(ChatGroupingSettings.activeWindowChoices, id: \.self) { minutes in
          Text(minutes == 60 ? "1 hour" : "\(minutes) \(minutes == 1 ? "minute" : "minutes")").tag(minutes)
        }
      } label: {
        Label("Active for", systemImage: "clock")
      }
      Toggle(isOn: $preferences.settings.unseenStayActive) {
        Label("Unseen chats stay Active", systemImage: "circle.inset.filled")
      }
      Picker(selection: $preferences.settings.unseenMarker) {
        ForEach(ChatUnseenMarker.allCases) { Text($0.title).tag($0) }
      } label: {
        Label("Unseen", systemImage: "textformat")
      }
      Picker(selection: $preferences.settings.pinnedOrder) {
        ForEach(ChatRowOrder.forPinned) { Text($0.title).tag($0) }
      } label: {
        Label("Pinned", systemImage: "pin")
      }
      Picker(selection: $preferences.settings.activeOrder) {
        ForEach(ChatRowOrder.forGroups) { Text($0.title).tag($0) }
      } label: {
        Label("Active", systemImage: "bolt")
      }
      Picker(selection: $preferences.settings.earlierOrder) {
        ForEach(ChatRowOrder.forGroups) { Text($0.title).tag($0) }
      } label: {
        Label("Earlier", systemImage: "archivebox")
      }
      Toggle(isOn: $preferences.settings.earlierCollapsed) {
        Label("Fold Earlier away", systemImage: "chevron.down")
      }
      Picker(selection: $preferences.settings.earlierLimit) {
        ForEach(ChatGroupingSettings.earlierLimitChoices, id: \.self) { limit in
          Text(limit.map { "\($0)" } ?? "All").tag(limit)
        }
      } label: {
        Label("Earlier chats shown", systemImage: "list.number")
      }
      Toggle(isOn: $preferences.settings.showsGroupTitles) {
        Label("Group titles", systemImage: "textformat.size")
      }
    } header: {
      Text("Chats")
    } footer: {
      Text("Active chats are working, waiting on you, unseen, or active in the last few minutes. Pins and these settings stay on this iPhone.")
    }
    .pickerStyle(.menu)
  }
}
