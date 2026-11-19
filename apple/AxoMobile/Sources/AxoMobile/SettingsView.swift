import AxoMobileModel
import SwiftUI
import UIKit

/// A compact settings directory; each real capability has its own native subpage.
struct SettingsView: View {
  let account: AccountSession
  let hosts: HostsModel
  let apps: AppsModel
  let chatList: ChatListPreferences
  var opening: Opening = .settings
  var openAppsInWorkbench: (() -> Void)? = nil
  let signOut: () -> Void
  @Environment(\.dismiss) private var dismiss
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white
  @State private var path = NavigationPath()
  @State private var confirmingSignOut = false

  enum Opening: String, Identifiable {
    case settings, apps
    var id: String { rawValue }
  }

  private enum Page: Hashable { case account, apps, appearance, chats, notifications }

  private var accountName: String {
    hosts.signedIn?.profile?.name ?? hosts.signedIn?.profile?.email ?? "Signed in"
  }

  private var appStatus: String {
    guard apps.phase == .loaded else { return "Connect apps" }
    let count = apps.apps.filter(\.isConnected).count + apps.servers.filter { $0.state == .ready }.count
    return "\(count) connected"
  }

  private var version: String {
    let info = Bundle.main.infoDictionary
    return "Axo \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
  }

  var body: some View {
    NavigationStack(path: $path) {
      landing
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Page.self) { destination in
          switch destination {
          case .account: accountPage
          case .apps: AppsView(model: apps)
          case .appearance: appearancePage
          case .chats: chatsPage
          case .notifications: notificationsPage
          }
        }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
              Image(systemName: "xmark").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close settings")
            .keyboardShortcut(.cancelAction)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button { UIPasteboard.general.string = version } label: {
                Label(version, systemImage: "doc.on.doc")
              }
            } label: {
              Image(systemName: "info.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("About Axo")
          }
        }
    }
    .onAppear { if opening == .apps, path.isEmpty { path.append(Page.apps) } }
    .task { await apps.refresh() }
    .alert("Sign out of Axo on this device?", isPresented: $confirmingSignOut) {
      Button("Sign out", role: .destructive) { dismiss(); signOut() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your hosts and conversations stay on your account.")
    }
    .frame(idealWidth: 640, idealHeight: 740)
    .presentationSizing(.form)
    .presentationDetents([.large])
    .presentationBackground(ChatColors.background)
    .tint(accentColor.color)
  }

  private var landing: some View {
    ScrollView {
      VStack(spacing: 24) {
        SettingsCard {
          destination(.account, "Profile", icon: "person.crop.circle", value: accountName)
        }
        SettingsCard {
          destination(.apps, "Apps", icon: "powerplug", value: appStatus,
            subtitle: "Accounts and MCP servers")
        }
        SettingsCard {
          destination(.appearance, "Appearance", icon: "paintpalette", value: appearance.title)
          divider
          destination(.chats, "Chats", icon: "bubble.left.and.bubble.right",
            subtitle: "Pinned, Active and Earlier")
          divider
          destination(.notifications, "Notifications", icon: "bell",
            subtitle: "Previews and request actions")
        }
        SettingsCard { signOutButton }
        Text(version).font(.footnote).foregroundStyle(.secondary)
      }
      .padding(20)
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
    }
    .background(ChatColors.background)
    .accessibilityIdentifier("settings-home")
  }

  private var notificationsPage: some View { NotificationPreferencesView() }

  private var divider: some View { Divider().padding(.leading, 56) }

  private func destination(_ page: Page, _ title: String, icon: String, value: String = "", subtitle: String? = nil) -> some View {
    let row = SettingsNavigationRow(title: title, icon: icon, value: value, subtitle: subtitle)
    return Group {
      if page == .apps, let openAppsInWorkbench {
        Button { dismiss(); openAppsInWorkbench() } label: { row }
      } else {
        NavigationLink(value: page) { row }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("settings-\(String(describing: page))")
  }

  private var accountPage: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SettingsCard {
          SettingsNavigationRow(title: accountName, icon: "person.crop.circle", subtitle: hosts.signedIn?.profile?.email,
            disclosure: false)
        }
        SettingsCard { signOutButton }
        Text("Signing out ends this device’s session. Your hosts and conversations stay on your account.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }
    .background(ChatColors.background)
    .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
  }

  private var appearancePage: some View {
    ScrollView {
      SettingsCard {
        HStack {
          Label("Appearance", systemImage: "moon")
          Spacer()
          Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden().pickerStyle(.menu).accessibilityIdentifier("appearance-picker")
        }
        .padding(18)
        Divider().padding(.leading, 56)
        HStack {
          Label("Accent color", systemImage: "paintpalette")
          Spacer()
          Picker("Accent color", selection: $accentColor) {
            ForEach(AppAccentColor.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden().pickerStyle(.menu).accessibilityIdentifier("accent-picker")
        }
        .padding(18)
      }
      .padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }
    .background(ChatColors.background)
    .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
  }

  private var chatsPage: some View {
    List { ChatListSettingsSection(preferences: chatList) }
      .listStyle(.insetGrouped).scrollContentBackground(.hidden)
      .background(ChatColors.background)
      .navigationTitle("Chats").navigationBarTitleDisplayMode(.inline)
  }

  private var signOutButton: some View {
    Button { confirmingSignOut = true } label: {
      SettingsNavigationRow(title: "Sign out", icon: "rectangle.portrait.and.arrow.right", disclosure: false)
        .foregroundStyle(.red)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Sign out")
  }
}

struct SettingsCard<Content: View>: View {
  let content: Content
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    VStack(spacing: 0) { content }
      .background(ChatColors.background, in: RoundedRectangle(cornerRadius: 26))
      .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
  }
}

private struct SettingsNavigationRow: View {
  let title: String
  let icon: String
  var value = ""
  var subtitle: String? = nil
  var disclosure = true

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: icon).font(.system(size: 20)).frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body)
        if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
      }
      Spacer(minLength: 8)
      if !value.isEmpty { Text(value).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
      if disclosure { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
    }
    .padding(.horizontal, 18).padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    .contentShape(Rectangle())
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
      Text("Active chats are working, waiting on you, or active in the last few minutes. Unread chats can remain in Earlier. Pins and these settings stay on this device.")
    }
    .pickerStyle(.menu)
  }
}
