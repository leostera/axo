import SwiftUI

struct AxodApplicationView: View {
    let coordinator: AxodWorkbenchCoordinator

    var body: some View {
        if coordinator.showsSetup {
            AxodSetupView(coordinator: coordinator)
        } else {
            AxodWorkbenchView(coordinator: coordinator)
        }
    }
}
