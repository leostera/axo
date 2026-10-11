import AxoProtocol
import SwiftUI

struct AxodChatHistoryView: View {
    let snapshot: PiChatSnapshot
    let coordinator: AxodWorkbenchCoordinator
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                AxodChatHistoryNavigation(snapshot: snapshot, presentationID: coordinator.historyWindow.presentationID, coordinator: coordinator)
                HStack {
                    if let first = coordinator.displayedChatEntries.first {
                        Button("Top of view") { proxy.scrollTo(first.entryId, anchor: .top) }
                    }
                    Spacer()
                    if let last = coordinator.displayedChatEntries.last {
                        Button("Bottom of view") { proxy.scrollTo(last.entryId, anchor: .bottom) }
                    }
                }
                .font(.caption).padding(.horizontal, 12).padding(.bottom, 5)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if coordinator.displayedChatEntries.isEmpty {
                            Text(coordinator.historyWindow.isLoading ? "Reading this canonical page…" : "No entries in this view.")
                                .font(.caption).foregroundStyle(Color.white.opacity(0.6))
                        }
                        ForEach(coordinator.displayedChatEntries, id: \.entryId) { entry in
                            AxodCanonicalHistoryEntryRow(entry: entry, snapshot: snapshot, coordinator: coordinator)
                                .id(entry.entryId)
                        }
                    }
                    .padding(12)
                }
                .id(coordinator.historyWindow.presentationID)
            }
        }
    }
}
