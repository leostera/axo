import AxoPhoneModel
import SwiftUI

struct ChatMessageView: View {
  let message: ChatMessage
  /// Pi is working now; a tool that has not answered is still running.
  var piIsWorking = false
  @State private var copied = false

  var body: some View {
    switch message.role {
    case .user:
      VStack(alignment: .trailing, spacing: 12) {
        Text(message.text)
          .font(.body).textSelection(.enabled)
          .padding(.horizontal, 17).padding(.vertical, 13)
          .background(Color.blue.opacity(0.24), in: RoundedRectangle(cornerRadius: 23))
          .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.blue.opacity(0.34), lineWidth: 0.5))
          .padding(.leading, 48)
          .contextMenu { copyButton; ShareLink(item: message.text) }
        if let timestamp = message.timestamp { MessageTimestamp(milliseconds: timestamp) }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .assistant:
      VStack(alignment: .leading, spacing: 16) {
        ChatMarkdown(blocks: message.blocks)
        HStack(spacing: 18) {
          copyButton
          ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("Share response")
          if let timestamp = message.timestamp { MessageTimestamp(milliseconds: timestamp) }
        }
        .font(.system(size: 16)).foregroundStyle(.secondary)
        .buttonStyle(.plain)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .thinking:
      ChatMarkdown(blocks: message.blocks, isThinking: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("thinkingBlock")
    case .tool:
      if let tool = message.tool { ToolTranscriptView(tool: tool, piIsWorking: piIsWorking) }
    }
  }

  private var copyButton: some View {
    Button {
      UIPasteboard.general.string = message.text
      copied = true
    } label: { Image(systemName: copied ? "checkmark" : "square.on.square") }
      .accessibilityLabel(copied ? "Copied response" : "Copy response")
  }
}

/// A message the phone sent that the agent has not recorded yet: the user's bubble, dimmed, with
/// where it is.
struct PendingPromptView: View {
  let prompt: HostWorkbenchModel.PendingPrompt

  private var label: String {
    switch prompt.state {
    case .sending: "Sending…"
    case .sent: "Sent"
    case .queued: "Queued · answered after the current reply"
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 12) {
      Text(prompt.text)
        .font(.body).textSelection(.enabled)
        .padding(.horizontal, 17).padding(.vertical, 13)
        .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.blue.opacity(0.24), lineWidth: 0.5))
        .padding(.leading, 48)
        .opacity(prompt.state == .sending ? 0.6 : 0.85)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("pendingPrompt")
  }
}

/// A reply, drawn where its look changes: prose, headings, bullets and code. Inline formatting
/// (bold, links, `code`) comes from the text view. Remote images are never fetched.
struct ChatMarkdown: View {
  let blocks: [MarkdownBlock]
  var isThinking = false
  @ScaledMetric(relativeTo: .body) private var bodySize = 18.0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .paragraph(let text):
          inline(text)
        case .heading(let level, let text):
          inline(text).font(.system(size: bodySize * (level == 1 ? 1.35 : level == 2 ? 1.15 : 1.05), weight: .semibold))
        case .listItem(let marker, let depth, let text):
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            switch marker {
            case .bullet: Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
            case .number(let number): Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            }
            inline(text)
          }
          .padding(.leading, CGFloat(depth) * bodySize * 1.2)
        case .quote(let text):
          inline(text)
            .foregroundStyle(.secondary)
            .padding(.leading, 17)
            .overlay(alignment: .leading) {
              RoundedRectangle(cornerRadius: 2).fill(Color.secondary).frame(width: 3)
            }
        case .table(let header, let rows):
          MarkdownTable(header: header, rows: rows)
        case .rule:
          Divider().padding(.vertical, 4)
        case .code(let language, let code):
          VStack(alignment: .leading, spacing: 10) {
            if let language { Text(language).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
              Text(code)
                .font(.system(size: bodySize * 0.85, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16))
        }
      }
    }
    .font(.system(size: isThinking ? bodySize * 0.85 : bodySize))
    .foregroundStyle(isThinking ? .secondary : .primary)
    .environment(\.openURL, OpenURLAction { url in
      ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
    })
  }

  /// Bold, italics, links and `code` within a line, as Markdown writes them.
  fileprivate static func inlineText(_ text: String) -> Text {
    let attributed = (try? AttributedString(
      markdown: text,
      options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    return Text(attributed)
  }

  private func inline(_ text: String) -> some View {
    Self.inlineText(text)
      .lineSpacing(bodySize * 0.2)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A table scrolls sideways rather than squeezing its columns; the header is bold, the rows are
/// separated by hairlines.
private struct MarkdownTable: View {
  let header: [String]
  let rows: [[String]]

  private func inline(_ cell: String) -> Text { ChatMarkdown.inlineText(cell) }

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
            inline(cell).fontWeight(.semibold).fixedSize()
          }
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          Divider().gridCellUnsizedAxes(.horizontal)
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
              inline(cell).fixedSize()
            }
          }
        }
      }
      .padding(14)
    }
    .scrollIndicators(.hidden)
    .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 16))
  }
}

struct ChatEmptyState: View {
  let message: String

  var body: some View {
    VStack(spacing: 18) {
      OwnMascotView()
        .frame(height: 72)
      Text("What are we working on?").font(.title2.weight(.semibold))
      Text(message).font(.body).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity).padding(.vertical, 90)
  }
}

/// Pi is busy; says so quietly under the last message.
struct AgentActivityView: View {
  /// A tool is running, as opposed to Pi only thinking.
  let callingTools: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles").foregroundStyle(.orange)
      Text(callingTools ? "Using tools…" : "Thinking…").font(.subheadline.weight(.medium))
      Spacer(minLength: 0)
      ProgressView().controlSize(.small).tint(.secondary)
    }
    .padding(.vertical, 6)
  }
}
