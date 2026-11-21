import AxoClient
import AxoProtocol
import SwiftUI

/// One confirmation, including retries. Once sent, its payload stays frozen unless the host
/// definitively rejects the folder or harness without creating a child.
public struct SessionForkSheet: View {
  let machine: String
  let plan: @MainActor () async throws -> SessionForkPlan
  let fork: @MainActor (UUID, String?, CodingAgent?) async throws -> SessionForkWebHandoff?
  @Environment(\.dismiss) private var dismiss
  @State private var confirmation: ForkConfirmation
  @State private var handoff: SessionForkWebHandoff?
  @State private var folder = ""
  @State private var checking = true
  @State private var submitting = false
  @State private var failure: String?

  public init(
    machine: String, retry: SessionForkAttempt? = nil,
    plan: @escaping @MainActor () async throws -> SessionForkPlan,
    fork: @escaping @MainActor (UUID, String?, CodingAgent?) async throws -> SessionForkWebHandoff?
  ) {
    self.machine = machine
    self.plan = plan
    self.fork = fork
    _confirmation = State(initialValue: ForkConfirmation(retry: retry))
    _checking = State(initialValue: retry == nil)
    _folder = State(initialValue: retry?.folder ?? "")
  }

  public var body: some View {
    Group {
      if let handoff {
        VStack(alignment: .leading, spacing: 14) {
          Text("Forked to \(handoff.agent.displayName) on \(machine)").font(.headline)
            .accessibilityAddTraits(.isHeader)
          Text("Open the new session in Axo on the web.").foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Link("Open in Web", destination: handoff.url).buttonStyle(.borderedProminent)
          }
        }
      } else {
        confirmationContent
      }
    }
    .padding(24)
    #if os(macOS)
    .frame(width: 440)
    #else
    .frame(idealWidth: 320, maxWidth: 360)
    .fixedSize(horizontal: false, vertical: true)
    #endif
    .interactiveDismissDisabled(submitting)
    .task { if confirmation.request == nil { await checkPlan() } }
  }

  private var confirmationContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Fork this session to \(machine)?")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(confirmation.request == nil
        ? "Copies chat history, not project files. The original session stays here."
        : "Retrying checks the same fork without creating a second session.")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      harness
      if confirmation.requiresFolder, confirmation.request == nil {
        destinationFolder
      } else if let path = confirmation.request?.folder {
        Text("Destination folder: \(path)").foregroundStyle(.secondary)
      }
      if let failure {
        Text(failure).font(.subheadline).foregroundStyle(.red)
      }
      HStack {
        if submitting { ProgressView().controlSize(.small).accessibilityLabel("Forking session") }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(submitting)
        confirmationButton
      }
    }
  }

  @ViewBuilder
  private var harness: some View {
    if checking {
      ProgressView("Checking compatible harnesses…").controlSize(.small)
    } else if confirmation.plan == nil, let attempt = confirmation.request, let agent = attempt.agent {
      Text("Harness: \(agent.displayName)").font(.subheadline)
    } else if let result = confirmation.plan {
      switch result.decision {
      case .keep:
        Text("Keep \(result.sourceAgent.displayName)").font(.subheadline)
      case .choose(let agents):
        Menu {
          ForEach(agents) { agent in
            Button(agent.displayName) { confirmation.selectedAgent = agent }
          }
        } label: {
          Label(confirmation.selectedAgent?.displayName ?? "Choose a harness", systemImage: "chevron.up.chevron.down")
        }
        .disabled(confirmation.request != nil)
        .accessibilityIdentifier("session-fork-harness")
      case .unavailable:
        Text("No compatible harness on \(machine). Choose another machine to fork this session.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var destinationFolder: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Choose a destination folder").font(.subheadline.weight(.semibold))
      TextField("Absolute folder path on \(machine)", text: $folder)
        .textFieldStyle(.roundedBorder)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #endif
        .accessibilityLabel("Destination folder on \(machine)")
        .accessibilityIdentifier("session-fork-folder")
    }
  }

  @ViewBuilder
  private var confirmationButton: some View {
    if confirmation.plan == nil, confirmation.request == nil, !checking {
      Button("Retry Check") { Task { await checkPlan() } }
    } else {
      Button(confirmation.request == nil ? "Fork" : "Retry Fork", action: submit)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(checking || submitting || !confirmation.canSubmit(folder: folder))
        .accessibilityIdentifier("session-fork-confirm")
    }
  }

  private func checkPlan() async {
    checking = true
    defer { checking = false }
    do {
      let result = try await plan()
      try Task.checkCancellation()
      confirmation.receive(result)
    } catch {
      if !Task.isCancelled { failure = error.localizedDescription }
    }
  }

  private func submit() {
    guard !checking, !submitting, let request = confirmation.submit(folder: folder) else { return }
    submitting = true
    failure = nil
    Task {
      defer { submitting = false }
      do {
        if let result = try await fork(request.id, request.folder, request.agent) {
          handoff = result
        } else {
          dismiss()
        }
      } catch SessionForkError.harnessUnavailable {
        confirmation.rejectHarness()
        failure = "The harness is no longer available. Review the updated options."
        await checkPlan()
      } catch {
        if SessionForkError.needsDestinationFolder(error) {
          confirmation.rejectFolder()
        } else {
          failure = error.localizedDescription
        }
      }
    }
  }
}
