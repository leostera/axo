import AxoMobileModel
import AxoWatchModel
import SwiftUI

struct WatchChatRow: View {
  let item: ConversationFeed.Item
  @ScaledMetric(relativeTo: .footnote) private var messageSize = 14.0

  var body: some View {
    switch WatchConversationContent(item.row) {
    case .assistant(let text):
      if case .message(let shown) = item.row, !shown.message.blocks.isEmpty {
        WatchMarkdown(blocks: shown.message.blocks)
      } else {
        Text(text).font(.system(size: messageSize)).frame(maxWidth: .infinity, alignment: .leading)
      }
    case .user(let text, let status):
      VStack(alignment: .trailing, spacing: 4) {
        Text(text).font(.system(size: messageSize))
          .padding(.horizontal, 10).padding(.vertical, 8)
          .background(Color.blue.opacity(status == nil ? 0.24 : 0.14), in: RoundedRectangle(cornerRadius: 14))
          .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.34), lineWidth: 0.5))
        if let status { Text(status).font(.caption2).foregroundStyle(.secondary) }
      }
      .padding(.leading, 22)
      .frame(maxWidth: .infinity, alignment: .trailing)
      .accessibilityElement(children: .combine)
    case nil: EmptyView()
    }
  }
}
