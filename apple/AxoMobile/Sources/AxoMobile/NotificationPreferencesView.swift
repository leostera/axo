import SwiftUI
import UIKit

/// Shared by Axo Settings and the notification inbox, never confused with iOS system permissions.
struct NotificationPreferencesView: View {
  @AppStorage(MobilePush.previewPreference) private var richPreviews = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        SettingsCard {
          Toggle("Show request and update text", isOn: $richPreviews)
            .padding(16)
            .accessibilityIdentifier("notification-rich-previews")
        }
        Text("Agent messages can appear in notifications and on your lock screen, subject to iOS preview settings. Short confirmations include Yes and No after unlocking. Sensitive input always opens Axo.")
          .font(.footnote).foregroundStyle(.secondary)
        SettingsCard {
          Button("iOS system permissions…") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
          }.padding(16)
        }
      }.padding(20).frame(maxWidth: 640).frame(maxWidth: .infinity)
    }
    .background(ChatColors.background)
    .navigationTitle("Notifications")
    .onChange(of: richPreviews) { _, _ in MobilePush.shared.previewsChanged() }
  }
}
