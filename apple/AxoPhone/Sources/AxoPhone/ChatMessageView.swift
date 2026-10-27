import AxoPhoneModel
import ImageIO
import SwiftUI

struct ChatMessageView: View {
  let message: ChatMessage
  /// Pi is working now; a tool that has not answered is still running.
  var piIsWorking = false
  /// Part of the reply being written: no actions until it is whole.
  var isLive = false
  @State private var copied = false

  var body: some View {
    let _ = RenderCount.note("Message")
    switch message.role {
    case .user:
      VStack(alignment: .trailing, spacing: 12) {
        if !message.images.isEmpty { ChatImagesView(images: message.images, alignment: .trailing) }
        if !message.text.isEmpty {
          Text(message.text)
            .font(.body).textSelection(.enabled)
            .padding(.horizontal, 17).padding(.vertical, 13)
            .background(Color.blue.opacity(0.24), in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.blue.opacity(0.34), lineWidth: 0.5))
            .padding(.leading, 48)
            .contextMenu { copyButton; ShareLink(item: message.text) }
        }
        if let timestamp = message.timestamp { MessageTimestamp(milliseconds: timestamp) }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .assistant:
      VStack(alignment: .leading, spacing: 16) {
        if !message.images.isEmpty { ChatImagesView(images: message.images, alignment: .leading) }
        ChatMarkdown(blocks: message.blocks)
        if !isLive {
        HStack(spacing: 18) {
          copyButton
          ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("Share response")
          if let timestamp = message.timestamp { MessageTimestamp(milliseconds: timestamp) }
        }
        .font(.system(size: 16)).foregroundStyle(.secondary)
        .buttonStyle(.plain)
        }
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

  /// For a message that may not have arrived: put its words back in the box, or take it away.
  var editAgain: () -> Void = {}
  var dismiss: () -> Void = {}

  private var label: String {
    switch prompt.state {
    case .sending: "Sending…"
    case .sent: "Sent"
    case .queued: "Queued · answered after the current reply"
    case .uncertain: "Delivery uncertain · check the chat before sending again"
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
        .contextMenu {
          if prompt.state == .uncertain {
            Button("Edit and send again", systemImage: "square.and.pencil", action: editAgain)
            Button("Remove", systemImage: "trash", role: .destructive, action: dismiss)
          }
        }
      HStack(spacing: 4) {
        if prompt.state == .uncertain { Image(systemName: "exclamationmark.triangle.fill") }
        Text(label)
      }
      .font(.caption).foregroundStyle(prompt.state == .uncertain ? Color.orange : Color.secondary)
      .multilineTextAlignment(.trailing)
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
    let _ = RenderCount.note("Markdown")
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

  /// Bold, italics, links and `code` within a line, read when the message was parsed.
  fileprivate static func inlineText(_ text: InlineText) -> Text { Text(text.styled) }

  private func inline(_ text: InlineText) -> some View {
    Self.inlineText(text)
      .lineSpacing(bodySize * 0.2)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A table scrolls sideways rather than squeezing its columns; the header is bold, the rows are
/// separated by hairlines.
private struct MarkdownTable: View {
  let header: [InlineText]
  let rows: [[InlineText]]

  private func inline(_ cell: InlineText) -> Text { ChatMarkdown.inlineText(cell) }

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
  /// The conversation's pull-to-refresh, which this Axo plays (`SlingMascotView`).
  var pull: ConversationPull?

  var body: some View {
    VStack(spacing: 18) {
      Group {
        if let pull { SlingMascotView(pull: pull) } else { OwnMascotView() }
      }
      .frame(height: 72)
      Text("What are we working on?").font(.title2.weight(.semibold))
      Text(message).font(.body).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity).padding(.vertical, 90)
  }
}

/// Pi is busy; says so quietly under the last message, with a way to stop it.
struct AgentActivityView: View {
  /// A tool is running, as opposed to Pi only thinking.
  let callingTools: Bool
  /// Pi is waiting for the person to answer.
  var waiting = false
  /// A stop was asked for and Pi has not stopped yet.
  var stopping = false
  var canStop = true
  var stop: () -> Void = {}
  @State private var confirmingStop = false

  private var title: String {
    if stopping { return "Stopping…" }
    if waiting { return "Waiting for your answer" }
    return callingTools ? "Using tools…" : "Thinking…"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "sparkles").foregroundStyle(.orange)
      Text(title).font(.subheadline.weight(.medium))
      Spacer(minLength: 0)
      ProgressView().controlSize(.small).tint(.secondary)
      Button { confirmingStop = true } label: {
        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
          .frame(width: 44, height: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop the reply")
      .disabled(stopping || !canStop)
    }
    .padding(.vertical, -4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agentActivity")
    .alert("Stop the reply?", isPresented: $confirmingStop) {
      Button("Stop", role: .destructive, action: stop)
      Button("Keep going", role: .cancel) {}
    } message: {
      Text("This stops everything the agent is doing now, including the tools it is running.")
    }
  }
}

/// What the agent is asking, with a way to answer it from here when that can be done.
struct QuestionCard: View {
  let question: ChatQuestion
  let canAnswer: Bool
  let answer: (HostWorkbenchModel.Answer) -> Void
  @State private var words = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(question.title ?? "The agent is asking something", systemImage: "questionmark.bubble")
        .font(.headline)
      switch question.kind {
      case .confirm:
        HStack(spacing: 12) {
          Button("Yes") { answer(.yes) }.buttonStyle(.borderedProminent)
          Button("No") { answer(.no) }.buttonStyle(.bordered)
        }
        .disabled(!canAnswer)
      case .input:
        HStack(spacing: 10) {
          TextField("Your answer", text: $words)
            .textFieldStyle(.roundedBorder)
            .submitLabel(.send)
            .onSubmit(sendWords)
          Button("Send", action: sendWords).buttonStyle(.borderedProminent)
            .disabled(!canAnswer || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Button("Skip", role: .cancel) { answer(.no) }.font(.callout).disabled(!canAnswer)
      case .select, .editor, .custom:
        Text("The choices are on your Mac. Answer there, or skip the question.")
          .font(.callout).foregroundStyle(.secondary)
        Button("Skip", role: .cancel) { answer(.no) }.font(.callout).disabled(!canAnswer)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ChatColors.surface, in: RoundedRectangle(cornerRadius: 20))
    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.orange.opacity(0.4), lineWidth: 1))
    .accessibilityIdentifier("questionCard")
  }

  private func sendWords() {
    let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard canAnswer, !text.isEmpty else { return }
    answer(.text(text))
    words = ""
  }
}

/// Pictures in a message, small; a tap opens one full screen.
struct ChatImagesView: View {
  let images: [ChatImage]
  let alignment: HorizontalAlignment
  @State private var opened: ChatImage?

  var body: some View {
    let side: CGFloat = images.count == 1 ? 220 : 120
    HStack(spacing: 8) {
      ForEach(images) { image in
        Button { opened = image } label: {
          DecodedImage(data: image.data, maxSide: side, fill: true)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image")
        .accessibilityHint("Opens it full screen")
      }
    }
    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    .fullScreenCover(item: $opened) { opened in
      FullScreenImage(data: opened.data)
    }
  }
}

/// A picture decoded at the size it is shown, away from the main actor: a photo in a message is
/// megapixels of data, and decoding it whole as its row scrolls into view drops frames.
private struct DecodedImage: View {
  let data: Data
  /// The longest side it is shown at, in points.
  let maxSide: CGFloat
  var fill = false
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image {
        if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
      } else {
        ChatColors.surface
      }
    }
    .task(id: maxSide) {
      image = await ImageDecoding.image(data, maxPixels: Int(maxSide * displayScale))
    }
  }
}

/// Decoded pictures, kept while memory allows. `NSCache` is safe to use from any thread.
private enum ImageDecoding {
  nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

  static func image(_ data: Data, maxPixels: Int) async -> UIImage? {
    // A picture is the same picture wherever it appears; the bytes' size and first bytes tell
    // them apart well enough for a cache key without hashing megabytes.
    let key = "\(maxPixels):\(data.count):\(data.prefix(64).base64EncodedString())" as NSString
    if let hit = cache.object(forKey: key) { return hit }
    let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
      guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
      let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1),
      ] as CFDictionary
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }.value
    if let decoded { cache.setObject(decoded, forKey: key) }
    return decoded
  }
}

/// One picture, full screen, pinch to zoom.
private struct FullScreenImage: View {
  let data: Data
  @State private var image: UIImage?
  @Environment(\.dismiss) private var dismiss
  @State private var scale: CGFloat = 1
  @GestureState private var pinch: CGFloat = 1

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.black.ignoresSafeArea()
      // Large enough to stay sharp when zoomed in, without decoding a huge photo whole.
      DecodedImage(data: data, maxSide: 1600)
        .scaleEffect(scale * pinch)
        .gesture(
          MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = min(max(scale * value.magnification, 1), 6) }
        )
        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
      HStack {
        Button { dismiss() } label: {
          Image(systemName: "xmark").font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white).frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Close image")
        Spacer()
        if let image {
          ShareLink(item: Image(uiImage: image), preview: SharePreview("Image", image: Image(uiImage: image))) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 20, weight: .semibold))
              .foregroundStyle(.white).frame(width: 48, height: 48)
              .background(.regularMaterial, in: Circle())
          }
          .accessibilityLabel("Share image")
        }
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 18).padding(.top, 12)
    }
    .environment(\.colorScheme, .dark)
    .statusBarHidden()
    // The original bytes, for sharing; decoded once, away from the main actor.
    .task { image = await Task.detached(priority: .userInitiated) { UIImage(data: data) }.value }
  }
}
