import AxoPhoneModel
import SwiftUI

/// Uses the phone's already-parsed blocks and inline styles; no second Markdown parser.
/// Code wraps and tables become labeled rows, instead of requiring sideways Crown scrolling.
struct WatchMarkdown: View {
  let blocks: [MarkdownBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        content(block)
      }
    }
    .font(.footnote)
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.openURL, OpenURLAction { url in
      ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
    })
  }

  @ViewBuilder private func content(_ block: MarkdownBlock) -> some View {
    switch block {
    case .paragraph(let text):
      prose(text)
    case .heading(let level, let text):
      prose(text)
        .font(level == 1 ? .headline : level == 2 ? .subheadline : .footnote)
        .fontWeight(.semibold)
        .padding(.top, 3)
        .accessibilityAddTraits(.isHeader)
    case .listItem(let marker, let depth, let text):
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(markerText(marker)).foregroundStyle(.secondary)
        prose(text)
      }
      .padding(.leading, CGFloat(min(depth, 3)) * 7)
    case .quote(let text):
      prose(text).foregroundStyle(.secondary).padding(.leading, 8)
        .overlay(alignment: .leading) { Capsule().fill(.secondary).frame(width: 2) }
    case .rule:
      Divider().padding(.vertical, 2)
    case .code(let language, let text):
      VStack(alignment: .leading, spacing: 4) {
        if let language { Text(language).font(.caption2).foregroundStyle(.secondary) }
        Text(verbatim: text)
          .font(.system(.caption2, design: .monospaced))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(7)
      .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    case .table(let header, let rows):
      table(header: header, rows: rows)
    }
  }

  private func prose(_ text: InlineText) -> some View {
    Text(text.styled).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .tint(.blue)
  }

  private func markerText(_ marker: ListMarker) -> String {
    switch marker {
    case .bullet: "•"
    case .number(let number): "\(number)."
    }
  }

  private func table(header: [InlineText], rows: [[InlineText]]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if rows.isEmpty {
        ForEach(header.indices, id: \.self) { prose(header[$0]).fontWeight(.semibold) }
      }
      ForEach(rows.indices, id: \.self) { row in
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(zip(header, rows[row]).enumerated()), id: \.offset) { _, cell in
            VStack(alignment: .leading, spacing: 1) {
              Text(cell.0.styled).fontWeight(.semibold).foregroundStyle(.secondary)
              prose(cell.1)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
      }
    }
  }
}
