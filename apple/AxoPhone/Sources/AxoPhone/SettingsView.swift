import AxoPhoneModel
import SwiftUI

struct SettingsView: View {
  let account: AccountSession
  let signOut: () -> Void
  @Environment(\.dismiss) private var dismiss
  @AppStorage("appearance") private var appearance: AppAppearance = .system
  @AppStorage("accentColor") private var accentColor: AppAccentColor = .white

  var body: some View {
    NavigationStack {
      List {
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
    .presentationDetents([.large])
    .presentationBackground(ChatColors.background)
    .tint(accentColor.color)
  }
}
