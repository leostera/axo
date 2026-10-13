import SwiftUI

@MainActor
struct PhoneWorkbenchView: View {
    @State private var workbenchModel: CentralPhoneWorkbenchModel
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    @AppStorage("accentColor") private var accentColor: AppAccentColor = .white

    init(model: CentralPhoneWorkbenchModel? = nil) {
        _workbenchModel = State(initialValue: model ?? CentralPhoneWorkbenchModel())
    }

    var body: some View {
        NavigationStack {
            CentralPhoneWorkbenchView(model: workbenchModel)
        }
        .preferredColorScheme(appearance.colorScheme)
        .tint(accentColor.color)
    }
}
