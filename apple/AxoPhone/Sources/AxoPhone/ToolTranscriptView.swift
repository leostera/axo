import AxoPhoneModel
import SwiftUI

/// A tool Pi used: a tinted card with what it ran; what came back stays folded until asked for,
/// as on the web, so a run of many tools stays short to scroll.
struct ToolTranscriptView: View {
  let tool: ToolActivity
  /// Pi is working now, so a tool that has not answered is still running.
  let piIsWorking: Bool
  @State private var expanded = false

  private var isRunning: Bool { tool.status == .running && piIsWorking }
  private var tint: Color {
    switch tool.status {
    case .running: isRunning ? .gray : .gray
    case .completed: .green
    case .failed: .red
    }
  }
  private var symbol: String {
    switch tool.kind {
    case .shell: "terminal"
    case .edit: "pencil.line"
    case .file: "doc.text"
    case .search: "magnifyingglass"
    case .generic: "wrench.and.screwdriver"
    }
  }
  private var corner: CGFloat { tool.kind == .shell ? 6 : 14 }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(tool.name, systemImage: symbol).font(.callout.weight(.semibold))
        Spacer()
        switch tool.status {
        case .running:
          if isRunning { ProgressView().controlSize(.small).accessibilityLabel("Running") }
        case .completed:
          Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Completed")
        case .failed:
          Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
      }
      if let subtitle = tool.subtitle, !subtitle.isEmpty {
        Text(subtitle).font(.caption.monospaced()).textSelection(.enabled)
      }
      if let command = tool.command, !command.isEmpty {
        Text("$ " + command)
          .font(.callout.monospaced()).textSelection(.enabled)
          .lineLimit(expanded ? nil : 4)
      }
      if !tool.output.isEmpty, expanded {
        Text(output)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if tool.outputTruncated {
          Text("Output cut short here; the rest is on your Mac.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      if !tool.output.isEmpty {
        Button {
          expanded.toggle()
        } label: {
          Label(foldTitle, systemImage: expanded ? "chevron.up" : "chevron.down")
            .labelStyle(.titleAndIcon)
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.17), in: RoundedRectangle(cornerRadius: corner))
    .overlay(RoundedRectangle(cornerRadius: corner).stroke(tint.opacity(0.32), lineWidth: 0.5))
    .accessibilityIdentifier("toolBlock")
  }

  private var lineCount: Int { tool.output.split(separator: "\n", omittingEmptySubsequences: false).count }

  /// "Show output (12 lines, still running)", or "Hide output".
  private var foldTitle: String {
    if expanded { return "Hide output" }
    let lines = "\(lineCount) \(lineCount == 1 ? "line" : "lines")"
    return "Show output (\(lines)\(isRunning ? ", still running" : ""))"
  }

  /// An edit's result is often a diff; its added and removed lines keep their colours.
  private var output: AttributedString {
    guard tool.kind == .edit, tool.status != .failed else { return AttributedString(tool.output) }
    var result = AttributedString()
    let lines = tool.output.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
      var segment = AttributedString(line + (index == lines.count - 1 ? "" : "\n"))
      if line.hasPrefix("+") { segment.foregroundColor = .green }
      if line.hasPrefix("-") { segment.foregroundColor = .red }
      result.append(segment)
    }
    return result
  }
}
