import AxoProtocol
import SwiftUI

struct AxodCanonicalHistoryEntryRow: View {
    let entry: PiCanonicalProjection
    let snapshot: PiChatSnapshot
    let coordinator: AxodWorkbenchCoordinator
    private var source: AxodToolOutput.Source? { AxodToolOutput.Source(entry: entry, snapshot: snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.toolName ?? entry.role ?? entry.kind.capitalized)
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                if let source {
                    Button(coordinator.toolOutput.source == source ? "Hide output" : "Inspect output", action: toggleOutput)
                        .font(.caption)
                        .disabled(coordinator.toolOutput.isLoading && coordinator.toolOutput.source != source)
                }
            }
            if let source, coordinator.toolOutput.source == source {
                AxodToolOutputView(source: source, reader: coordinator.toolOutput, coordinator: coordinator)
            } else {
                Text(entry.text.isEmpty ? "[No text content]" : entry.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88)).textSelection(.enabled)
                if entry.truncated {
                    Text(source == nil ? "Entry preview was clipped by the bounded canonical projection." : "Tool preview was clipped. Inspect output to read its pages.")
                        .font(.caption2).foregroundStyle(Color.orange.opacity(0.85))
                }
            }
            if !entry.toolCalls.isEmpty {
                Text("Tools: \(entry.toolCalls.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }
    private func toggleOutput() {
        guard let source else { return }
        if coordinator.toolOutput.source == source { coordinator.closeToolOutput() }
        else { coordinator.openToolOutput(entry: entry, snapshot: snapshot) }
    }
}
