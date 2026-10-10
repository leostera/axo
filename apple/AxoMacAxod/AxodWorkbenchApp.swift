import SwiftUI

@main
struct AxodWorkbenchApp: App {
    @State private var coordinator = AxodWorkbenchCoordinator()

    var body: some Scene {
        Window("Axo", id: "main") {
            AxodWorkbenchView(coordinator: coordinator)
                .frame(minWidth: 760, minHeight: 520)
                .task { coordinator.connect() }
        }
        .defaultSize(width: 1040, height: 700)
    }
}
