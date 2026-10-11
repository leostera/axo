import AxoProtocol
import SwiftUI

struct AxodChatHistoryNavigation: View {
    let snapshot: PiChatSnapshot
    let presentationID: UUID
    let coordinator: AxodWorkbenchCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Recent", action: recent).disabled(coordinator.historyWindow.mode == .recent)
                Button("Beginning", action: beginning).disabled(coordinator.historyWindow.isLoading)
                if coordinator.historyWindow.mode == .page {
                    Button("Previous page", action: previous).disabled(!coordinator.historyWindow.canGoBack)
                    Button("Next page", action: next).disabled(!coordinator.historyWindow.canGoForward)
                }
                Spacer()
                if coordinator.historyWindow.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Reading canonical history") }
            }
            Text(coordinator.historyWindow.mode == .recent ? "Recent canonical entries — older history is available from Beginning." : "Captured page \(coordinator.historyWindow.previous.count + 1). Entries stay in Pi's canonical order.")
                .foregroundStyle(Color.white.opacity(0.6))
            if let issue = coordinator.historyWindow.issue {
                Text(issue.rawValue).foregroundStyle(Color.orange)
            }
            if coordinator.historyWindow.isAtPositionLimit {
                Text(AxodChatHistoryWindow.Issue.capacity.rawValue).foregroundStyle(Color.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
    private func recent() {
        coordinator.showRecentChatHistory(source: .init(target: snapshot.target, readMode: snapshot.readMode))
    }
    private func beginning() { coordinator.loadChatHistoryPage(snapshot: snapshot, movement: .beginning, presentationID: presentationID) }
    private func previous() { coordinator.loadChatHistoryPage(snapshot: snapshot, movement: .previous, presentationID: presentationID) }
    private func next() { coordinator.loadChatHistoryPage(snapshot: snapshot, movement: .next, presentationID: presentationID) }
}
