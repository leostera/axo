import AxoCore
import SwiftUI

struct ToolTranscriptView: View {
    let message: ConversationMessage
    let activity: AgentActivity?
    let outputState: ToolOutputState?
    let loadOutput: () -> Void
    @State private var expanded = false

    private var status: AgentActivityStatus {
        if let status = message.status, status != .running { return status }
        return activity?.status ?? message.status ?? .running
    }
    private var kind: ToolPresentation.Kind { message.toolPresentation?.kind ?? .generic }
    private var preview: String { status == .running ? activity?.output ?? message.output ?? "" : message.output ?? "" }
    private var output: String {
        if expanded, let state = outputState, !state.text.isEmpty { return state.text }
        return preview
    }
    private var tint: Color {
        switch status {
        case .running: .gray
        case .completed: .green
        case .failed: .red
        }
    }
    private var symbol: String {
        switch kind {
        case .shell: "terminal"
        case .edit: "pencil.line"
        case .file: "doc.text"
        case .search: "magnifyingglass"
        case .generic: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(message.toolPresentation?.title ?? message.toolName ?? "Tool", systemImage: symbol)
                    .font(.callout.weight(.semibold))
                Spacer()
                switch status {
                case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
                case .completed: Image(systemName: "checkmark").foregroundStyle(.green).accessibilityLabel("Completed")
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
                }
            }
            if let subtitle = message.toolPresentation?.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption.monospaced()).textSelection(.enabled)
            }
            if kind == .shell {
                Text("$ " + message.text).font(.callout.monospaced()).textSelection(.enabled)
            } else if kind != .edit || output.isEmpty {
                if !message.text.isEmpty {
                    toolText(message.text, diff: kind == .edit, limit: expanded ? nil : 4)
                }
            }
            if !output.isEmpty { toolText(output, diff: kind == .edit && status != .failed, limit: expanded ? nil : 6) }
            Button(expanded ? "Collapse tool output" : "Expand tool output") {
                expanded.toggle()
                if expanded && status != .running && outputState == nil { loadOutput() }
            }
            .font(.caption).foregroundStyle(.secondary)
            if expanded {
                if outputState?.isLoading == true { ProgressView("Loading output…").font(.caption) }
                if let error = outputState?.error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Retry loading output", action: loadOutput).font(.caption)
                } else if outputState?.isLoading != true, outputState?.nextOffset != nil {
                    Button("Load more output", action: loadOutput).font(.caption)
                }
                if status == .running { Text("Full output is available when the tool finishes.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.17), in: RoundedRectangle(cornerRadius: kind == .shell ? 6 : 14))
        .overlay(RoundedRectangle(cornerRadius: kind == .shell ? 6 : 14).stroke(tint.opacity(0.32), lineWidth: 0.5))
        .accessibilityIdentifier("toolBlock-\(status.rawValue)")
        .onChange(of: status) { _, status in
            if expanded && status != .running && outputState == nil { loadOutput() }
        }
    }

    private func toolText(_ value: String, diff: Bool, limit: Int?) -> some View {
        Text(diff ? styledDiff(value) : AttributedString(value))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(limit)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func styledDiff(_ value: String) -> AttributedString {
        var result = AttributedString()
        let lines = value.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var segment = AttributedString(line + (index == lines.count - 1 ? "" : "\n"))
            if line.hasPrefix("+") { segment.foregroundColor = .green }
            if line.hasPrefix("-") { segment.foregroundColor = .red }
            result.append(segment)
        }
        return result
    }
}
