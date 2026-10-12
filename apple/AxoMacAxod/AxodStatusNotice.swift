import SwiftUI

/// Workbench notices expose only the human-readable state and available action.
struct AxodStatusNotice<Actions: View>: View {
    let title: String
    let actions: Actions

    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(10)
    }
}
