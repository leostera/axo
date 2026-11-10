import AxoClient
import AxoProtocol
import AxoPhoneModel
import ImageIO
import SwiftUI

struct ChatMessageView: View {
  let message: ChatMessage
  /// Pi is working now; a tool that has not answered is still running.
  var piIsWorking = false
  /// Part of the reply being written: no actions until it is whole.
  var isLive = false
  /// How it comes in, when it was written while the chat is on screen (`ConversationReveal`).
  var entrance: Entrance?
  /// A tool's place among the tools used one after another.
  var group: ToolGroupPlace?
  /// A tool's: whether its row is open, and the way to open or fold it.
  var toolOpened: (isOpen: Bool, toggle: () -> Void)?
  @State private var copied = false

  /// A message written while its chat is on screen: its words let out, or a rise.
  struct Entrance {
    let reveal: ConversationReveal
    let presentation: ConversationReveal.Presentation
    /// Its row, whose `revealed` says how much of its words are out while the feed's clock lets
    /// them out (RFD0039). Read by the words alone, so each step redraws them and not the message.
    let item: ConversationFeed.Item
  }

  /// Being let out: the feed's clock decides how much shows.
  private var revealing: Bool {
    guard let entrance, case .reveal = entrance.presentation else { return false }
    return true
  }

  @ViewBuilder private func prose(isThinking: Bool) -> some View {
    if revealing, let item = entrance?.item {
      RevealedWords(item: item, text: message.text, blocks: message.blocks, isThinking: isThinking)
    } else {
      ChatMarkdown(blocks: message.blocks, isThinking: isThinking)
    }
  }

  var body: some View {
    content
      .modifier(RiseIn(key: message.key, entrance: entrance))
  }

  @ViewBuilder private var content: some View {
    // The one growing (being written, or its words let out) apart from the rest, which should not
    // redraw at all as it grows.
    let _ = RenderCount.note(isLive || revealing ? "Growing" : "Message")
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
        prose(isThinking: false)
        if !isLive && !revealing {
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
      prose(isThinking: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("thinkingBlock")
    case .tool:
      if let tool = message.tool { ToolTranscriptView(tool: tool, piIsWorking: piIsWorking, group: group, opened: toolOpened) }
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
    case .queued: QueuedPromptView.label(prompt.delivery)
    case .uncertain: "Not confirmed yet · trying again"
    case .waitingForPi: "Waiting for Pi to start…"
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 12) {
      if !prompt.attachments.isEmpty {
        Text(prompt.attachments.map { "📎 \($0.name)" }.joined(separator: "\n"))
          .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
      }
      if !prompt.text.isEmpty {
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

/// A message Pi took while busy and has not started on, as the log holds it (RFD0033): the user's
/// bubble, dimmed, saying when Pi takes it: next, at its next step, or once the turn ends.
struct QueuedPromptView: View {
  let prompt: QueuedPrompt

  static func label(_ delivery: PromptDelivery) -> String {
    switch delivery {
    case .interrupt: "Interrupting · answered next"
    case .steer: "Steering · at the agent's next step"
    case .followUp: "Queued · after the current reply"
    }
  }

  static func icon(_ delivery: PromptDelivery) -> String {
    switch delivery {
    case .interrupt: "bolt"
    case .steer: "arrow.turn.down.right"
    case .followUp: "clock"
    }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 12) {
      if !prompt.attachments.isEmpty {
        Text(prompt.attachments.map { "📎 \($0)" }.joined(separator: "\n"))
          .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
      }
      if !prompt.text.isEmpty {
        Text(prompt.text)
          .font(.body).textSelection(.enabled)
          .padding(.horizontal, 17).padding(.vertical, 13)
          .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 23))
          .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.blue.opacity(0.24), lineWidth: 0.5))
          .padding(.leading, 48)
          .opacity(0.85)
      }
      HStack(spacing: 4) {
        Image(systemName: Self.icon(prompt.delivery))
        Text(Self.label(prompt.delivery))
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("queuedPrompt")
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
            .scrollsSideways()
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
    .scrollsSideways()
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

/// Pi is busy; says so quietly under the last message, with a way to stop it: the x stops it at
/// once, without asking, as on the web.
struct AgentActivityView: View {
  /// A tool is running, as opposed to Pi only thinking.
  let callingTools: Bool
  /// Pi is waiting for the person to answer.
  var waiting = false
  /// A stop was asked for and Pi has not stopped yet.
  var stopping = false
  var canStop = true
  var stop: () -> Void = {}

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
      Button(action: stop) {
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
  }
}

/// What a Mac's agent asks the person (RFD0029). Only the person answers: the agent waits for Yes
/// or No, and an answer from any of their devices settles it everywhere.
struct ElicitationCard: View {
  let question: AskedQuestion
  let canAnswer: Bool
  /// Why the last answer did not go.
  var failure: String?
  let answer: (ElicitationAnswer) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        // Axo's computer-use gate asks before an action it stopped; only axod's own tools can.
        Group {
          switch question.elicitation.askedBy {
          case .computerUse: Label("Axo asks before acting on your Mac", systemImage: "desktopcomputer")
          case .agent: Label("The agent asks you", systemImage: "questionmark.bubble")
          }
        }
        .font(.callout.weight(.semibold))
        Spacer()
        if question.answering != nil { ProgressView().controlSize(.small) }
      }
      Text(question.elicitation.message)
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 8) {
        Button("Yes") { answer(.accept) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("elicitationYes")
        Button("No") { answer(.decline) }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("elicitationNo")
      }
      .controlSize(.small)
      .buttonBorderShape(.capsule)
      .disabled(!canAnswer || question.answering != nil)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.17), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.32), lineWidth: 0.5))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("elicitationCard")
  }
}

/// Values the agent must not see, for a form on the person's Mac (RFD0029). What it shows is the
/// Mac's own reading of the window; what the person types is sealed to that Mac before it leaves
/// the phone, and the agent only learns that the fields were filled. The fields carry autofill
/// hints, so Passwords and 1Password offer the login.
struct InputCard: View {
  let question: AskedQuestion
  let canAnswer: Bool
  var failure: String?
  let answer: (ElicitationAnswer, [String: String]?) -> Void
  @State private var values: [String: String] = [:]
  @FocusState private var focused: String?

  private var input: InputRequest { question.elicitation.input! }
  private var complete: Bool { input.fields.allSatisfy { !(values[$0.id] ?? "").isEmpty } }
  private var disabled: Bool { !canAnswer || question.answering != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Axo asks you to sign in on your Mac", systemImage: "key.fill")
          .font(.callout.weight(.semibold))
        Spacer()
        if question.answering != nil { ProgressView().controlSize(.small) }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(input.origin ?? input.window).font(.body.weight(.semibold)).textSelection(.enabled)
        Text("in \(input.app)\(input.submit.map { ", then “\($0)”" } ?? "")").font(.footnote).foregroundStyle(.secondary)
      }
      ForEach(input.fields) { field in
        entry(for: field)
          .textFieldStyle(.roundedBorder)
          .disabled(disabled)
          .focused($focused, equals: field.id)
          .submitLabel(field.id == input.fields.last?.id ? .done : .next)
          .onSubmit { submit(after: field) }
      }
      Text("Goes straight to your Mac, encrypted for it. The agent never sees it.")
        .font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("Fill in") { send() }
          .buttonStyle(.borderedProminent)
          .disabled(disabled || !complete)
          .accessibilityIdentifier("inputFill")
        Button("Cancel") { answer(.decline, nil) }
          .buttonStyle(.bordered)
          .disabled(disabled)
          .accessibilityIdentifier("inputCancel")
      }
      .controlSize(.small)
      .buttonBorderShape(.capsule)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.17), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.32), lineWidth: 0.5))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inputCard")
  }

  @ViewBuilder
  private func entry(for field: InputRequest.Field) -> some View {
    let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = String($0.prefix(1000)) })
    let title = field.label.isEmpty ? field.kind.rawValue.capitalized : field.label
    switch field.kind {
    case .password:
      SecureField(title, text: binding).textContentType(.password)
    case .username:
      TextField(title, text: binding).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
    case .email:
      TextField(title, text: binding).textContentType(.username).keyboardType(.emailAddress)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    case .code:
      TextField(title, text: binding).textContentType(.oneTimeCode).keyboardType(.numberPad)
    case .text:
      TextField(title, text: binding)
    }
  }

  private func submit(after field: InputRequest.Field) {
    let ids = input.fields.map(\.id)
    if let index = ids.firstIndex(of: field.id), index + 1 < ids.count {
      focused = ids[index + 1]
    } else {
      send()
    }
  }

  private func send() {
    guard complete, !disabled else { return }
    answer(.accept, values)
    values = [:]
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
    // Several pictures scroll sideways in their own row rather than widen the conversation's
    // column: a row wider than the screen pushed every message off its edge.
    ScrollView(.horizontal) {
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
    }
    .scrollIndicators(.hidden)
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .scrollsSideways()
    // The person's pictures sit on the right, as their words do, until there are too many.
    .defaultScrollAnchor(alignment == .trailing ? .trailing : .leading)
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

/// A reply's words as far as the feed's clock has let them out; all of them once it is done.
private struct RevealedWords: View {
  let item: ConversationFeed.Item
  let text: String
  let blocks: [MarkdownBlock]
  let isThinking: Bool

  var body: some View {
    if let revealed = item.revealed, revealed < text.count {
      // Only the row being let out parses as it goes; never half a word (`RevealPace`).
      ChatMarkdown(blocks: MarkdownBlocks.parse(String(text.prefix(revealed))), isThinking: isThinking)
    } else {
      ChatMarkdown(blocks: blocks, isThinking: isThinking)
    }
  }
}

/// A message that arrived while its chat is on screen comes up from just below, once.
private struct RiseIn: ViewModifier {
  let key: String
  let entrance: ChatMessageView.Entrance?
  @State private var risen = false

  private var rises: Bool { entrance?.presentation == .rise }

  func body(content: Content) -> some View {
    content
      .opacity(rises && !risen ? 0 : 1)
      .offset(y: rises && !risen ? 14 : 0)
      .onAppear {
        guard rises, let entrance else { return }
        withAnimation(.easeOut(duration: 0.28)) { risen = true } completion: { entrance.reveal.rose(key) }
      }
  }
}
