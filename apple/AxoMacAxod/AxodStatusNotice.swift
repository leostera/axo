import SwiftUI

/// Keep the action and human-readable state visible; diagnostics are opt-in.
struct AxodStatusNotice<Actions: View>: View {
    let title: String
    let details: String
    let actions: Actions

    init(_ title: String, details: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.details = details
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            if !details.isEmpty {
                DisclosureGroup("Details") {
                    Text(details).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(10)
    }
}
