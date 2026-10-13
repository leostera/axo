import AppKit
import AxoCore
import AxoProtocol
import SwiftUI

struct AxodPiConversationPresentation: Equatable {
    let id: UUID
    let source: CentralSource
    let sessionID: UUID
}

struct AxodPiInputPresentation: Equatable {
    let conversation: AxodPiConversationPresentation
    let target: CentralPiBindingTarget
}

private struct AxodPiConversationReadIdentity: Equatable {
    let source: CentralSource?
    let sessionID: UUID?
}

enum AxodPiEditOrigin: Equatable {
    case direct
    case capturedPaste(CentralEditCapture)
    case rejectedPaste

    static func resolve(isPasting: Bool, capture: CentralEditCapture?) -> Self {
        guard isPasting else { return .direct }
        guard let capture else { return .rejectedPaste }
        return .capturedPaste(capture)
    }
}

@MainActor
final class AxodPiConversationWindowDelegate: NSObject, NSWindowDelegate {
    private let didClose: () -> Void
    init(didClose: @escaping () -> Void) { self.didClose = didClose }
    func windowWillClose(_ notification: Notification) { didClose() }
}

struct AxodPiConversationView: View {
    @Bindable var coordinator: AxodWorkbenchCoordinator
    let source: CentralSource
    let sessionID: UUID
    @State private var editNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            conversationContent
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: AxodPiConversationReadIdentity(source: coordinator.catalog?.source, sessionID: coordinator.selectedSessionID)) {
            guard coordinator.catalog?.source == source, coordinator.selectedSessionID == sessionID else { return }
            await coordinator.refreshSelectedPi()
        }
    }

    @ViewBuilder private var conversationContent: some View {
        if coordinator.catalog?.source != source {
            unavailable("The central store changed. Reopen this conversation to observe the current session.")
        } else if coordinator.selectedSessionID != sessionID {
            unavailable("The selected session changed. Reopen this conversation from its session row.")
        } else if coordinator.selectedPiReadUnavailable {
            VStack(spacing: 12) {
                Text("Conversation unavailable").font(.headline)
                Text("Axod could not confirm this exact Pi binding. No new conversation was created.")
                    .foregroundStyle(.secondary)
                Button("Refresh") { Task { await coordinator.refreshSelectedPi() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if let observation = coordinator.selectedPiObservation {
            switch observation {
            case .notAdmitted:
                unavailable("Pi has not published an admitted conversation for this session. Axo will not create a replacement chat.")
            case .stopped(let target):
                history(for: target, readMode: .stopped)
                Text("Pi is stopped. This canonical history is read-only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            case .live(let target, _):
                history(for: target, readMode: .live)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Observing the selected Pi binding…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var composer: some View {
        if coordinator.selectedSessionID == sessionID,
           let observation = coordinator.selectedPiObservation,
           case .live(let target, _) = observation,
           let conversation = coordinator.piConversationPresentation(for: sessionID, source: source),
           let input = try? coordinator.piInputPresentation(matching: conversation),
           input.target == target {
            AxodPiComposerEditor(
                coordinator: coordinator,
                presentation: input,
                onIssue: { editNotice = $0 }
            )
            .id(conversation.id)
            .frame(minHeight: 82, idealHeight: 126, maxHeight: 170)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            composerActions(input)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        } else if coordinator.selectedSessionID == sessionID,
                  let observation = coordinator.selectedPiObservation,
                  case .live = observation {
            Text("Pi input is waiting for an exact live snapshot.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func history(for target: CentralPiBindingTarget, readMode: CentralPiHistoryReadMode) -> some View {
        Group {
            if let page = coordinator.selectedPiHistory,
               page.target == target, page.readMode == readMode {
                if page.entries.isEmpty {
                    VStack(spacing: 8) {
                        Text("No committed messages in this branch.").foregroundStyle(.secondary)
                        Button("Refresh") { Task { await coordinator.refreshSelectedPi() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(page.entries) { entry in
                                AxodPiHistoryEntryView(entry: entry)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("Conversation history")
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading the exact canonical branch…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func composerActions(_ input: AxodPiInputPresentation) -> some View {
        let state = coordinator.selectedPiState
        let text = coordinator.piInputText(matching: input)
        let waiting = state.map { $0.pending || $0.recovery || $0.uiWaits > 0 || $0.question != nil } ?? true
        let canSend = state.map { !$0.recovery && !$0.pending && $0.uiWaits == 0 && $0.question == nil && (!$0.busy || $0.interactionId != nil) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            if let question = state?.question {
                Text(question.title).font(.callout).accessibilityAddTraits(.isHeader)
                HStack {
                    ForEach(question.options, id: \.id) { option in
                        Button(option.label) {
                            coordinator.submitPiControl(.answer(optionId: option.id), matching: input)
                        }
                        .disabled(!coordinator.supportsCentralPiSubmission || state?.recovery == true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pi question answers")
            }
            if let editNotice { Text(editNotice).font(.footnote).foregroundStyle(.secondary) }
            if let message = coordinator.piInputMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("Axo.PiConversation.SubmissionStatus")
            }
            HStack {
                if state?.busy == true, state?.interactionId != nil {
                    Button("Cancel response", systemImage: "xmark.circle") {
                        coordinator.submitPiControl(.cancel, matching: input)
                    }
                    .disabled(!coordinator.supportsCentralPiSubmission || state?.recovery == true)
                    .accessibilityIdentifier("Axo.PiConversation.Cancel")
                }
                Spacer()
                Button(state?.busy == true ? "Steer" : "Send", systemImage: "arrow.up.circle.fill") {
                    coordinator.submitPiInput(matching: input)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!coordinator.supportsCentralPiSubmission || !canSend || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"))
                .accessibilityIdentifier("Axo.PiConversation.Submit")
            }
            if !coordinator.supportsCentralPiSubmission {
                Text("This Axod does not advertise central Pi submission. Input remains local and will not be sent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if waiting {
                Text("Input is unavailable while Pi is waiting for a response or recovery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if coordinator.catalog?.source == source, coordinator.selectedSessionID == sessionID {
                Button("Refresh") { Task { await coordinator.refreshSelectedPi() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct AxodPiHistoryEntryView: View {
    let entry: CentralPiCanonicalProjection

    private var author: String {
        switch entry.role?.lowercased() {
        case "user": "You"
        case "assistant": "Pi"
        case .some(let role): role
        case .none: entry.kind
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp).font(.caption2).foregroundStyle(.tertiary)
            }
            if !entry.text.isEmpty {
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.toolCalls.isEmpty {
                ForEach(entry.toolCalls, id: \.id) { call in
                    Label(call.name, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.truncated {
                Text("This canonical entry is truncated.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(author) message")
    }
}

private struct AxodPiComposerEditor: NSViewRepresentable {
    let coordinator: AxodWorkbenchCoordinator
    let presentation: AxodPiInputPresentation
    let onIssue: (String?) -> Void

    func makeCoordinator() -> EditorCoordinator {
        EditorCoordinator(coordinator: coordinator, presentation: presentation, onIssue: onIssue)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let editor = AxodPiTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.font = .preferredFont(forTextStyle: .body)
        editor.delegate = context.coordinator
        editor.pasteCapture = { [weak coordinator] in
            try? coordinator?.capturePiEdit(matching: presentation)
        }
        editor.releasePasteCapture = { [weak coordinator] capture in
            coordinator?.inputBuffers.releaseEmptyEditingCapture(capture)
        }
        editor.setAccessibilityLabel("Message for selected Pi conversation")
        editor.setAccessibilityIdentifier("Axo.PiConversation.Editor")
        scroll.documentView = editor
        context.coordinator.textView = editor
        context.coordinator.updatePresentation(presentation)
        editor.string = coordinator.piInputText(matching: presentation)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? AxodPiTextView else { return }
        context.coordinator.update(presentation: presentation, onIssue: onIssue)
        editor.pasteCapture = { [weak coordinator] in
            try? coordinator?.capturePiEdit(matching: presentation)
        }
        editor.releasePasteCapture = { [weak coordinator] capture in
            coordinator?.inputBuffers.releaseEmptyEditingCapture(capture)
        }
        let expected = coordinator.piInputText(matching: presentation)
        guard editor.string != expected, !editor.hasMarkedText() else { return }
        let ranges = editor.selectedRanges
        editor.string = expected
        let length = (expected as NSString).length
        editor.selectedRanges = ranges.map { value in
            let range = value.rangeValue
            let location = min(range.location, length)
            let clampedLength = min(range.length, length - location)
            return NSValue(range: NSRange(location: location, length: clampedLength))
        }
    }

    @MainActor
    final class EditorCoordinator: NSObject, NSTextViewDelegate {
        private let workbench: AxodWorkbenchCoordinator
        private var presentation: AxodPiInputPresentation
        private var onIssue: (String?) -> Void
        weak var textView: AxodPiTextView?

        init(coordinator: AxodWorkbenchCoordinator, presentation: AxodPiInputPresentation, onIssue: @escaping (String?) -> Void) {
            workbench = coordinator
            self.presentation = presentation
            self.onIssue = onIssue
        }

        func updatePresentation(_ presentation: AxodPiInputPresentation) { self.presentation = presentation }
        func update(presentation: AxodPiInputPresentation, onIssue: @escaping (String?) -> Void) {
            self.presentation = presentation
            self.onIssue = onIssue
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let current = textView.string as NSString
            guard NSMaxRange(affectedCharRange) <= current.length else { return false }
            let updated = current.replacingCharacters(in: affectedCharRange, with: replacementString ?? "")
            do {
                let editor = textView as? AxodPiTextView
                let origin = AxodPiEditOrigin.resolve(
                    isPasting: editor?.isApplyingPasteCapture == true,
                    capture: editor?.pendingPasteCapture
                )
                switch origin {
                case .direct:
                    try workbench.editPiInput(updated, matching: presentation)
                case .capturedPaste(let capture):
                    guard try workbench.applyPiInput(updated, matching: capture, presentation: presentation) else {
                        onIssue("This paste no longer belongs to the current Pi binding. Its text was not applied.")
                        return false
                    }
                case .rejectedPaste:
                    onIssue("Paste requires an exact live Pi editing capture. Its text was not applied.")
                    return false
                }
                onIssue(nil)
                return true
            } catch CentralInputIssue.textCapacity {
                onIssue("Message limit reached. Shorten the text before continuing.")
                return false
            } catch {
                onIssue("The selected Pi binding changed. Reopen the conversation before editing.")
                return false
            }
        }
    }
}

private final class AxodPiTextView: NSTextView {
    var pasteCapture: (() -> CentralEditCapture?)?
    var releasePasteCapture: ((CentralEditCapture) -> Void)?
    fileprivate(set) var pendingPasteCapture: CentralEditCapture?
    fileprivate(set) var isApplyingPasteCapture = false

    override func paste(_ sender: Any?) {
        let capture = pasteCapture?()
        pendingPasteCapture = capture
        isApplyingPasteCapture = true
        defer {
            isApplyingPasteCapture = false
            pendingPasteCapture = nil
            if let capture { releasePasteCapture?(capture) }
        }
        super.paste(sender)
    }
}
