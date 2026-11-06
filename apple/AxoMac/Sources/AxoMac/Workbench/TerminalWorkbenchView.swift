import AppKit
import AxoDaemonManager
import AxoProtocol
import SwiftUI

struct TerminalWorkbenchView: View {
  var daemon: DaemonController
  var sessions: TerminalSessionsModel
  @Binding var isPresentingWorkspaceCreation: Bool
  var daemonIsRunningOverride: Bool? = nil
  @Environment(GhosttyRuntime.self) private var ghostty
  @Environment(\.displayScale) private var displayScale
  @State private var terminalAreaSize: CGSize = .zero

  private var daemonIsRunning: Bool {
    if let daemonIsRunningOverride { return daemonIsRunningOverride }
    if case .running = daemon.status { return true }
    return false
  }

  var body: some View {
    HStack(spacing: 0) {
      // Its own view: Session status and names change on every Pi turn, and only the sidebar
      // presents them. The terminal area reads pane-level projections that those leave alone.
      WorkbenchSidebar(sessions: sessions, isPresentingWorkspaceCreation: $isPresentingWorkspaceCreation)

      Divider()

      terminalContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { terminalAreaSize = $0 }
        // Over the panes, not beside them: a question must not resize the terminals.
        .overlay(alignment: .bottomTrailing) {
          ElicitationCards(model: sessions.elicitations, sessionID: sessions.selectedSessionID)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          if daemonIsRunning, case .reconnecting(let reason) = sessions.catalogConnection {
            CatalogReconnectingBanner(reason: reason)
          }
        }
    }
    .onChange(of: OffscreenSizing(area: terminalAreaSize, scale: displayScale, layouts: sessions.sessionLayouts), initial: true) {
      _, sizing in
      ghostty.surfaces.scheduleOffscreenSizing(
        layouts: sizing.layouts.map(TerminalLayout.init),
        terminalAreaSize: sizing.area,
        backingScale: sizing.scale)
    }
    .onChange(of: ViewportReport(area: terminalAreaSize, scale: displayScale, cell: ghostty.cellPixelSize), initial: true) {
      _, report in
      if let viewport = ghostty.viewport(terminalAreaSize: report.area, backingScale: report.scale) {
        sessions.reportViewport(viewport)
      }
    }
    // Full-height content: the terminal reaches the window's top edge; the sidebar's
    // WindowDragStrip stands in for the hidden title bar.
    .ignoresSafeArea(.container, edges: .top)
    .frame(minWidth: 760, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    .sheet(isPresented: $isPresentingWorkspaceCreation) {
      WorkspaceCreationSheet(sessions: sessions)
    }
    .confirmationDialog(
      "Archive \(sessions.pendingWorkspaceArchiveConfirmation?.workspaceName ?? "Workspace")?",
      isPresented: Binding(
        get: { sessions.pendingWorkspaceArchiveConfirmation != nil },
        set: { isPresented in
          if !isPresented { sessions.cancelWorkspaceArchiveConfirmation() }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Archive Workspace and Sessions", role: .destructive) {
        guard let confirmation = sessions.pendingWorkspaceArchiveConfirmation else { return }
        Task { await sessions.confirmWorkspaceArchiveAndCloseSession(confirmation) }
      }
      .accessibilityIdentifier("confirm-archive-workspace-last-session")

      Button("Cancel", role: .cancel) {
        sessions.cancelWorkspaceArchiveConfirmation()
      }
    } message: {
      if let confirmation = sessions.pendingWorkspaceArchiveConfirmation {
        Text(
          "This is the last Session in “\(confirmation.workspaceName)”. "
            + "Archiving this Workspace will close its Sessions and preserve their histories."
        )
      }
    }
    .confirmationDialog(
      "Close this pane?",
      isPresented: Binding(
        get: { sessions.pendingShellCloseConfirmation != nil },
        set: { isPresented in
          if !isPresented { sessions.cancelShellCloseConfirmation() }
        }
      ),
      titleVisibility: .visible,
      presenting: sessions.pendingShellCloseConfirmation
    ) { confirmation in
      Button("Close Pane", role: .destructive) {
        Task { await sessions.confirmShellClose(confirmation) }
      }
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("confirm-close-busy-shell")
      Button("Cancel", role: .cancel) {
        sessions.cancelShellCloseConfirmation()
      }
    } message: { confirmation in
      Text(confirmation.reason.message)
    }
  }

  /// What offscreen panes are sized from: the terminal area, its scale, and every Session's layout.
  private struct OffscreenSizing: Equatable {
    var area: CGSize
    var scale: CGFloat
    var layouts: [SessionLayout]
  }

  /// What Axod sizes unshown panes from: the terminal area, its scale, and the cell size.
  private struct ViewportReport: Equatable {
    var area: CGSize
    var scale: CGFloat
    var cell: ClientViewport.PixelSize?
  }

  private var presentedTerminalLayout: TerminalLayoutPresentation? {
    guard let layout = sessions.layout else { return nil }
    let presentation = TerminalLayoutPresentation(layout)
    guard let pending = sessions.pendingTerminalSplit,
      pending.sessionID == sessions.selectedSessionID
    else { return presentation }
    return presentation.inserting(pending) ?? presentation
  }

  @ViewBuilder
  private var terminalContent: some View {
    if let message = sessions.errorMessage, !sessions.hasSessions {
      ContentUnavailableView(
        "Couldn’t Load Sessions", systemImage: "exclamationmark.triangle",
        description: Text(message))
    } else if let layout = presentedTerminalLayout {
      TerminalLayoutView(layout: layout, sessions: sessions)
        .id(layout.structuralIdentity)
    } else {
      // Axod's own states (starting, restarting, needing approval) live on the launch splash.
      ContentUnavailableView(
        "No Session Selected", systemImage: "terminal",
        description: Text("Choose a session in the sidebar or create a new one."))
    }
  }
}

/// Shown while the catalog stream is down, so stale Sessions never look live.
private struct CatalogReconnectingBanner: View {
  let reason: String

  var body: some View {
    Label {
      Text("Lost connection to axod. Reconnecting… (\(reason))")
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      ProgressView().controlSize(.small)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.yellow.opacity(0.18))
    .accessibilityIdentifier("catalog-reconnecting")
  }
}

extension ShellCloseConfirmation.Reason {
  var message: String {
    switch self {
    case .runningProcess(let name?):
      "“\(name)” is still running in this pane. Closing it will terminate the process."
    case .runningProcess(nil):
      "A process is still running in this pane. Closing it will terminate the process."
    case .piWorking:
      "Pi is working on a turn. Closing this pane stops it; the conversation history is preserved."
    case .unknown:
      "Axo couldn’t check whether this pane is running something. Closing it will terminate anything still running."
    }
  }
}

/// What the selected Session's agent, or Axo's computer-use gate, asks the person (RFD0029): one
/// card per question, with Yes and No. An answer from any device settles it everywhere.
struct ElicitationCards: View {
  var model: ElicitationsModel
  var sessionID: SessionID?

  var body: some View {
    let questions = model.questions(in: sessionID)
    if !questions.isEmpty || !model.waitingDevices.isEmpty {
      VStack(alignment: .trailing, spacing: 8) {
        ForEach(model.waitingDevices) { device in
          DeviceCard(device: device, deciding: model.deciding.contains(device.key)) { allow in
            Task { await model.decide(device.key, allow: allow) }
          }
        }
        ForEach(questions) { question in
          if question.input != nil {
            InputCard(
              question: question, answering: model.answering.contains(question.id),
              failure: model.failure
            ) { action, values in
              Task { await model.answer(question.id, action, values: values) }
            }
          } else {
            ElicitationCard(
              question: question, answering: model.answering.contains(question.id),
              failure: model.failure
            ) { action in
              Task { await model.answer(question.id, action) }
            }
          }
        }
      }
      .padding(16)
      .frame(maxWidth: 440)
    }
  }
}

/// Values the agent must not see, for a form in an app on this Mac (RFD0029): what it shows is
/// axod's own reading of the window, and what the person types goes only to axod, which fills
/// it in. The fields carry autofill hints, so Passwords and 1Password offer the login.
struct InputCard: View {
  let question: Elicitation
  let answering: Bool
  var failure: String?
  let answer: (ElicitationAnswer, [String: String]?) -> Void
  @State private var values: [String: String] = [:]

  private var input: InputRequest { question.input! }
  private var complete: Bool { input.fields.allSatisfy { !(values[$0.id] ?? "").isEmpty } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Axo asks you to sign in", systemImage: "key.fill").font(.callout.weight(.semibold))
        Spacer()
        if answering { ProgressView().controlSize(.small) }
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(input.origin ?? input.window).font(.body.weight(.semibold)).textSelection(.enabled)
        Text("in \(input.app)\(input.submit.map { ", then “\($0)”" } ?? "")").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(input.fields) { field in
        entry(for: field).textFieldStyle(.roundedBorder).disabled(answering).onSubmit(send)
      }
      Text("Goes straight into the app. The agent never sees it.").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("Fill in", action: send)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(answering || !complete)
          .accessibilityIdentifier("inputFill")
        Button("Cancel") { answer(.decline, nil) }
          .buttonStyle(.bordered)
          .disabled(answering)
          .accessibilityIdentifier("inputCancel")
      }
      .controlSize(.small)
      .buttonBorderShape(.capsule)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .background(Color.blue.opacity(0.17), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.32), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("inputCard")
  }

  @ViewBuilder
  private func entry(for field: InputRequest.Field) -> some View {
    let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = String($0.prefix(1000)) })
    let title = field.label.isEmpty ? field.kind.rawValue.capitalized : field.label
    switch field.kind {
    case .password: SecureField(title, text: binding).textContentType(.password)
    case .username, .email: TextField(title, text: binding).textContentType(.username)
    case .code: TextField(title, text: binding).textContentType(.oneTimeCode)
    case .text: TextField(title, text: binding)
    }
  }

  private func send() {
    guard complete, !answering else { return }
    answer(.accept, values)
    values = [:]
  }
}

/// A phone or a browser answered a question without being allowed to (RFD0029): the person checks
/// that the fingerprint here is the one the device shows, so only their own devices answer.
struct DeviceCard: View {
  let device: AnsweringDevice
  let deciding: Bool
  let decide: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Allow \(device.name) to answer for this Mac?", systemImage: "iphone.gen3.badge.exclamationmark")
          .font(.callout.weight(.semibold))
        Spacer()
        if deciding { ProgressView().controlSize(.small) }
      }
      Text(device.fingerprint)
        .font(.title3.monospaced().weight(.semibold))
        .textSelection(.enabled)
        .accessibilityIdentifier("deviceFingerprint")
      Text("Allow it only if \(device.name) shows these same characters. It can then say yes to agents and computer use here.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Allow") { decide(true) }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("deviceAllow")
        Button("Not mine") { decide(false) }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("deviceRefuse")
      }
      .controlSize(.small)
      .buttonBorderShape(.capsule)
      .disabled(deciding)
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.32), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("deviceCard")
  }
}

struct ElicitationCard: View {
  let question: Elicitation
  let answering: Bool
  var failure: String?
  let answer: (ElicitationAnswer) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Group {
          switch question.askedBy {
          case .computerUse: Label("Axo asks before acting on your Mac", systemImage: "desktopcomputer")
          case .agent: Label("The agent asks you", systemImage: "questionmark.bubble")
          }
        }
        .font(.callout.weight(.semibold))
        Spacer()
        if answering { ProgressView().controlSize(.small) }
      }
      Text(question.message)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
      .disabled(answering)
      if let failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .background(Color.blue.opacity(0.17), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.32), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("elicitationCard")
  }
}
