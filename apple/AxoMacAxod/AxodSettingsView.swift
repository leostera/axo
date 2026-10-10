import SwiftUI

struct AxodSettingsView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator

    var body: some View {
        MacSettingsView(
            voice: coordinator.voice,
            onNotificationSettingChanged: { coordinator.notificationPreferenceChanged($0) },
            openNotificationSettings: { coordinator.openNotificationSettings() }
        )
    }
}
