import AxoPhoneModel
import SwiftUI

/// A tool the agent used: a row saying what it is and what it works on, in a block with the tools
/// used just before and after it. As on the web.
///
/// While it runs, the row shows the start of what it was given and the newest line it printed.
/// Tapped (running or not), it opens to what it was given and what it printed so far, still coming
/// in; "See full output" shows all of it, on a sheet of its own. What came back starts folded once
/// it is done, so a run of many tools stays short to scroll.
struct ToolTranscriptView: View {
  let tool: ToolActivity
  /// Pi is working now, so a tool that has not answered is still running.
  let piIsWorking: Bool
  /// Its place among the tools used one after another.
  var group: ToolGroupPlace?
  /// Whether it is open, and the way to open or fold it, when its row keeps that (in the
  /// conversation's list, `ConversationFeed.Item.open`); otherwise the view keeps it.
  var opened: (isOpen: Bool, toggle: () -> Void)?
  @State private var openHere = false
  @State private var viewing = false

  private var open: Bool { opened?.isOpen ?? openHere }

  /// How many lines of a running tool's input show before it is opened.
  private static let previewLines = 3
  /// How many lines of what it was given, and of what it printed, an open row shows; the sheet shows all.
  private static let openLines = 24

  private var isRunning: Bool { tool.status == .running && piIsWorking }
  private var symbol: String {
    switch tool.kind {
    case .shell: "terminal"
    case .edit: "pencil.line"
    case .file: "doc.text"
    case .search: "magnifyingglass"
    case .generic: "wrench.and.screwdriver"
    }
  }
  private var lineCount: Int { tool.output.isEmpty ? 0 : tool.output.split(separator: "\n", omittingEmptySubsequences: false).count }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let title = group?.title {
        Text(title)
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          .padding(.horizontal, 14).padding(.top, 10)
          .accessibilityIdentifier("toolGroupTitle")
      }
      row
      // For a screenshot or a read image, the picture is what it came back with: shown folded too.
      if !tool.images.isEmpty {
        ToolImagesView(images: tool.images)
          .padding(.leading, 40).padding(.trailing, 14).padding(.bottom, 10)
      }
      if open {
        openedContent
      } else if isRunning {
        glance
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.gray.opacity(0.17), in: shape)
    .overlay(shape.stroke(Color.gray.opacity(0.32), lineWidth: 0.5))
    .overlay(alignment: .top) {
      // Joined to the row above it: a hairline between them, where the outline's top would be.
      if group?.first == false { Rectangle().fill(Color.gray.opacity(0.32)).frame(height: 0.5) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("toolBlock")
    .sheet(isPresented: $viewing) {
      ToolOutputSheet(tool: tool, running: isRunning)
    }
  }

  /// Its outline: rounded where the block starts and ends, square where it joins the rows beside it.
  private var shape: UnevenRoundedRectangle {
    let top: CGFloat = group == nil || group?.first == true ? 12 : 0
    let bottom: CGFloat = group == nil || group?.last == true ? 12 : 0
    return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top)
  }

  private var row: some View {
    Button {
      if let opened { opened.toggle() } else { openHere.toggle() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol).font(.footnote).foregroundStyle(.secondary).frame(width: 18)
        Text(tool.name).font(.subheadline.weight(.semibold))
          .foregroundStyle(tool.status == .failed ? Color.red : Color.primary)
        Text(tool.preview)
          .font(.caption.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
        status
        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(tool.name)\(tool.preview.isEmpty ? "" : " \(tool.preview)")\(isRunning ? ", running" : "")")
    .accessibilityValue(open ? "Open" : "Folded")
    .accessibilityIdentifier("toolRow")
  }

  @ViewBuilder private var status: some View {
    switch tool.status {
    case .running:
      if isRunning { ProgressView().controlSize(.small).accessibilityLabel("Running") }
    case .completed:
      Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.green).accessibilityLabel("Completed")
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
    }
  }

  /// Running and folded: the start of what it was given (unless the row says all of it), and the
  /// newest line it printed.
  @ViewBuilder private var glance: some View {
    let input = tool.input.flatMap { input in
      input.kind != .arguments && input.text.trimmingCharacters(in: .whitespacesAndNewlines) != tool.preview ? input : nil
    }
    let last = tool.output.components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if input != nil || last != nil {
      VStack(alignment: .leading, spacing: 4) {
        if let input { Text(Self.firstLines(input.text, Self.previewLines)).foregroundStyle(.secondary) }
        if let last { Text(last).lineLimit(1).accessibilityIdentifier("toolLastLine") }
      }
      .font(.caption.monospaced())
      .padding(.leading, 40).padding(.trailing, 14).padding(.bottom, 10)
    }
  }

  /// Open: what it was given, and what it printed so far (its end, while more comes).
  private var openedContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let input = tool.input {
        ToolText(text: input.kind == .command ? "$ " + input.text : input.text, diff: input.kind == .diff, lines: Self.openLines, end: false)
          .accessibilityIdentifier("toolInput")
      }
      if !tool.output.isEmpty {
        ToolText(text: tool.output, diff: tool.kind == .edit && tool.status != .failed, lines: Self.openLines, end: true)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("toolOutput")
      } else if isRunning {
        Text("Nothing printed yet.").font(.caption).foregroundStyle(.secondary)
      }
      if isRunning || lineCount > Self.openLines || (tool.input?.text.components(separatedBy: "\n").count ?? 0) > Self.openLines {
        Button("See full output (\(lineCount) \(lineCount == 1 ? "line" : "lines"))") { viewing = true }
          .font(.caption).accessibilityIdentifier("seeFullOutput")
      }
      if tool.outputTruncated {
        Text("Cut short here; the rest is on your Mac.").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14).padding(.bottom, 12)
  }

  static func firstLines(_ text: String, _ count: Int) -> String {
    let lines = text.components(separatedBy: "\n")
    return lines.count > count ? lines.prefix(count).joined(separator: "\n") + "\n…" : text
  }
}

/// Monospaced text in a box, at most `lines` of it: its start, or (`end`) its end, as a running
/// tool's newest output is what matters. A diff keeps its added and removed lines' colours.
private struct ToolText: View {
  let text: String
  let diff: Bool
  let lines: Int
  let end: Bool

  var body: some View {
    Text(shown)
      .font(.caption.monospaced())
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12).padding(.vertical, 10)
      .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }

  private var shown: AttributedString {
    var all = text.components(separatedBy: "\n")
    var cut: String?
    if all.count > lines {
      cut = "… \(all.count - lines) more \(all.count - lines == 1 ? "line" : "lines")"
      all = end ? Array(all.suffix(lines)) : Array(all.prefix(lines))
    }
    var result = AttributedString()
    if end, let cut { result.append(Self.note(cut + "\n")) }
    for (index, line) in all.enumerated() {
      var segment = AttributedString(line + (index == all.count - 1 ? "" : "\n"))
      if diff, line.hasPrefix("+") { segment.foregroundColor = .green }
      if diff, line.hasPrefix("-") { segment.foregroundColor = .red }
      result.append(segment)
    }
    if !end, let cut { result.append(Self.note("\n" + cut)) }
    return result
  }

  private static func note(_ text: String) -> AttributedString {
    var note = AttributedString(text)
    note.foregroundColor = .secondary
    return note
  }
}

/// All of a tool's output, on a sheet of its own; while it runs, more comes in at the end, which
/// stays in view.
private struct ToolOutputSheet: View {
  let tool: ToolActivity
  let running: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let input = tool.input {
            ToolText(text: input.kind == .command ? "$ " + input.text : input.text, diff: input.kind == .diff, lines: .max, end: false)
          }
          if tool.output.isEmpty {
            Text(running ? "Nothing printed yet." : "It printed nothing.").font(.caption).foregroundStyle(.secondary)
          } else {
            ToolText(text: tool.output, diff: tool.kind == .edit && tool.status != .failed, lines: .max, end: true)
              .accessibilityIdentifier("fullOutput")
          }
          if tool.outputTruncated {
            Text("Cut short here; the rest is on your Mac.").font(.caption2).foregroundStyle(.secondary)
          }
        }
        .padding()
      }
      .defaultScrollAnchor(.bottom, for: .sizeChanges)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .navigationTitle("\(tool.name) output")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          VStack(spacing: 0) {
            Text("\(tool.name) output").font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("fullOutputLines")
          }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDetents([.large])
  }

  private var subtitle: String {
    let lines = tool.output.isEmpty ? 0 : tool.output.components(separatedBy: "\n").count
    return "\(lines) \(lines == 1 ? "line" : "lines")\(running ? ", still running" : "")"
  }
}
