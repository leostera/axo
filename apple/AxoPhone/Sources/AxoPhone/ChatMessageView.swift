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
        case .bullet(let text):
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•").foregroundStyle(.secondary)
            inline(text)
          }
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

  private func inline(_ text: String) -> some View {
    let attributed = (try? AttributedString(
      markdown: text,
      options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    return Text(attributed)
      .lineSpacing(bodySize * 0.2)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
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
      Text(callingTools ? "Pi is calling tools…" : "Pi is thinking…").font(.subheadline.weight(.medium))
      Spacer(minLength: 0)
      ProgressView().controlSize(.small).tint(.secondary)
    }
    .padding(.vertical, 6)
  }
}
