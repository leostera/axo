import AppKit
import AxoProtocol
import SwiftUI
import os

/// What agents and Axo's computer-use gate ask the person on this Mac (RFD0029), in a panel that
/// drops down from the menu bar Axo, centered under it: every question, one after the other, each
/// answered in place. It closes like a menu, when the person clicks elsewhere or presses Escape,
/// and by itself once nothing is left to answer.
///
/// Not on losing the keyboard: the menu that opens it gives the keyboard back to the app in front
/// as it closes, which would close the panel as soon as it showed.
@MainActor
final class QuestionsPanel {
  static let shared = QuestionsPanel()
  private static let log = Logger(subsystem: "dev.leostera.axo", category: "questions")

  /// The menu bar item's frame on screen, to hang the panel under.
  var anchor: () -> NSRect? = { nil }

  private var panel: Panel?
  /// Clicks outside the panel, in other apps and in Axo's own windows, while it shows.
  private var clickMonitors: [Any] = []

  /// Shows the panel under the menu bar Axo, or brings it forward.
  func show(_ model: ElicitationsModel) {
    let panel = self.panel ?? makePanel(model)
    self.panel = panel
    place(panel)
    panel.orderFrontRegardless()
    panel.makeKey()
    watchClicksOutside(panel)
    Self.log.info("event=questions_panel.shown questions=\(model.questions.count) frame=\(NSStringFromRect(panel.frame), privacy: .public)")
  }

  func close() {
    guard let panel, panel.isVisible else { return }
    panel.orderOut(nil)
    for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
    clickMonitors = []
  }

  private func watchClicksOutside(_ panel: Panel) {
    guard clickMonitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }) {
      clickMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self, weak panel] event in
      if event.window !== panel { self?.close() }
      return event
    }) {
      clickMonitors.append(local)
    }
  }

  private func makePanel(_ model: ElicitationsModel) -> Panel {
    let panel = Panel(
      contentRect: NSRect(x: 0, y: 0, width: QuestionsList.width, height: 200),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.onCancel = { [weak self] in self?.close() }
    let hosting = NSHostingView(
      rootView: QuestionsList(model: model, close: { [weak self] in self?.close() }))
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentView = hosting
    // Grows and shrinks as questions come and go, keeping its top under the menu bar.
    hosting.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: hosting, queue: .main
    ) { [weak self, weak panel] _ in
      MainActor.assumeIsolated {
        guard let self, let panel, panel.isVisible else { return }
        self.place(panel)
      }
    }
    return panel
  }

  /// Centered under the menu bar Axo, a few points below the menu bar, kept on its screen.
  private func place(_ panel: NSPanel) {
    let size = panel.contentView?.fittingSize ?? panel.frame.size
    let screen = panel.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return }
    let anchor = anchor() ?? NSRect(x: visible.midX, y: visible.maxY, width: 0, height: 0)
    let height = min(size.height, visible.height - 12)
    var x = anchor.midX - size.width / 2
    x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
    let top = min(anchor.minY, visible.maxY) - 6
    panel.setFrame(NSRect(x: x, y: top - height, width: size.width, height: height), display: true)
  }

  /// Takes the keyboard for the forms' fields without bringing Axo's windows forward.
  final class Panel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
  }
}

/// The panel's content: every waiting question, oldest first.
struct QuestionsList: View {
  static let width: CGFloat = 380

  var model: ElicitationsModel
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(model.questions.count == 1 ? "1 question" : "\(model.questions.count) questions")
          .font(.headline)
        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(model.questions.enumerated()), id: \.element.id) { index, question in
            if index > 0 { Divider().padding(.horizontal, 14) }
            QuestionRow(
              question: question,
              session: model.sessionName(question.sessionId),
              answering: model.answering.contains(question.id),
              isFirst: index == 0,
              showSession: {
                model.showSession(question.sessionId)
                close()
              },
              answer: { action, values in Task { await model.answer(question.id, action, values: values) } })
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      if let failure = model.failure {
        Text(failure).font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 14).padding(.bottom, 10)
      }
    }
    .frame(width: Self.width)
    .fixedSize(horizontal: false, vertical: true)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    .onChange(of: model.questions.isEmpty) { _, empty in if empty { close() } }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("questionsPanel")
  }
}

/// One question: who asks and from which Session, what, and its answers. The first question's
/// main answer takes Return.
private struct QuestionRow: View {
  let question: Elicitation
  let session: String
  let answering: Bool
  let isFirst: Bool
  let showSession: () -> Void
  let answer: (ElicitationAnswer, [String: String]?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Group {
          switch (question.input != nil, question.askedBy) {
          case (true, _): Label("Sign in", systemImage: "key.fill")
          case (false, .computerUse): Label("Before acting on your Mac", systemImage: "desktopcomputer")
          case (false, .agent): Label("The agent asks", systemImage: "questionmark.bubble")
          }
        }
        .font(.callout.weight(.semibold))
        Spacer(minLength: 8)
        if answering { ProgressView().controlSize(.small) }
        Button(session, action: showSession)
          .buttonStyle(.link)
          .font(.caption)
          .lineLimit(1)
          .help("Show this Session")
      }
      if let input = question.input {
        InputFields(input: input, answering: answering, isFirst: isFirst, answer: answer)
      } else {
        Text(question.message)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("Yes") { answer(.accept, nil) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(isFirst ? .defaultAction : nil)
            .accessibilityIdentifier("elicitationYes")
          Button("No") { answer(.decline, nil) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("elicitationNo")
        }
        .controlSize(.small)
        .disabled(answering)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("elicitationCard")
  }
}

/// Values the agent must not see, for a form in an app on this Mac (RFD0029): what it shows is
/// axod's own reading of the window, and what the person types goes only to axod, which fills
/// it in. The fields carry autofill hints, so Passwords and 1Password offer the login.
private struct InputFields: View {
  let input: InputRequest
  let answering: Bool
  let isFirst: Bool
  let answer: (ElicitationAnswer, [String: String]?) -> Void
  @State private var values: [String: String] = [:]

  private var complete: Bool { input.fields.allSatisfy { !(values[$0.id] ?? "").isEmpty } }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(input.origin ?? input.window).font(.body.weight(.semibold)).textSelection(.enabled)
        Text("in \(input.app)\(input.submit.map { ", then “\($0)”" } ?? "")")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(input.fields) { field in
        entry(for: field).textFieldStyle(.roundedBorder).disabled(answering).onSubmit(send)
      }
      Text("Goes straight into the app. The agent never sees it.")
        .font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button("Fill in", action: send)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(isFirst ? .defaultAction : nil)
          .disabled(answering || !complete)
          .accessibilityIdentifier("inputFill")
        Button("Cancel") { answer(.decline, nil) }
          .buttonStyle(.bordered)
          .disabled(answering)
          .accessibilityIdentifier("inputCancel")
      }
      .controlSize(.small)
    }
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
