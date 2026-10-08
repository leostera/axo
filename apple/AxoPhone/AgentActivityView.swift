import AxoCore
import SwiftUI

/// Run controls are separate from the transcript's durable thinking and tool blocks.
struct AgentActivityView: View {
    let state: AgentState?
    let runId: String?
    let activities: [AgentActivity]
    let canCancel: Bool
    let isCancelling: Bool
    let cancelRun: (String) -> Void

    @State private var showsCancelConfirmation = false
    @State private var selectedRunID: String?

    private var isActive: Bool { state == .running || state == .waiting }
    private var runningTools: Bool { activities.contains { $0.status == .running } }

    var body: some View {
        if isActive {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
                ProgressView().controlSize(.small).tint(.secondary)
                Button(action: requestCancellation) {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                }
                .accessibilityLabel("Cancel Pi run")
                .disabled(!canCancel || isCancelling || runId == nil)
            }
            .padding(.vertical, 6)
            .alert("Cancel Pi's current run?", isPresented: $showsCancelConfirmation) {
                Button("Cancel Pi run", role: .destructive) {
                    if let selectedRunID { cancelRun(selectedRunID) }
                    selectedRunID = nil
                }
                Button("Keep running", role: .cancel) { selectedRunID = nil }
            } message: {
                Text("This stops the current Pi run, including its active tool calls. It does not cancel only one tool.")
            }
        }
    }

    private var title: String {
        if isCancelling { return "Cancelling Pi…" }
        if runningTools { return "Pi is calling tools…" }
        if state == .waiting { return "Pi is waiting for your input" }
        return "Pi is thinking…"
    }

    private func requestCancellation() {
        guard !isCancelling, let runId else { return }
        selectedRunID = runId
        showsCancelConfirmation = true
    }
}
