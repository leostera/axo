import SwiftUI

struct AxodToolOutputView: View {
    let source: AxodToolOutput.Source
    let reader: AxodToolOutput
    let coordinator: AxodWorkbenchCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page = reader.page {
                Text(page.text.isEmpty ? "[No text output]" : page.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .textSelection(.enabled)
                Text("Bytes \(page.offset)–\(page.offset + page.text.utf8.count) of \(page.totalBytes)")
                    .font(.caption).foregroundStyle(Color.white.opacity(0.6))
                HStack {
                    Button("Previous page", action: previous).disabled(!reader.canGoBack)
                    Button("Next page", action: next).disabled(!reader.canGoForward)
                    Spacer()
                    if reader.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Reading canonical output") }
                }
            } else if reader.isLoading {
                ProgressView("Reading recorded output…").controlSize(.small)
            }
            if reader.isAtPositionLimit {
                Text(AxodToolOutput.Issue.capacity.rawValue).font(.caption).foregroundStyle(Color.orange)
            }
            if let issue = reader.issue {
                Text(issue.rawValue).font(.caption).foregroundStyle(Color.orange)
                if reader.page == nil, issue == .failed {
                    Button("Retry read", action: retry).disabled(reader.isLoading)
                }
            }
            Text("Read-only Pi output. One bounded page is shown at a time.")
                .font(.caption2).foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
    }
    private func previous() { coordinator.loadToolOutput(source: source, movement: .previous) }
    private func next() { coordinator.loadToolOutput(source: source, movement: .next) }
    private func retry() { coordinator.loadToolOutput(source: source, movement: .first) }
}
