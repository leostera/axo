import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Own the native paste boundary rather than inspecting SwiftUI's private views.
struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var hasMultipleLines: Bool
    let focused: Binding<Bool>
    let pasteAttachments: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.allowsEditingTextAttributes = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier, UTType.image.identifier, UTType.fileURL.identifier, UTType.data.identifier])
        view.accessibilityIdentifier = "promptDraft"
        view.accessibilityLabel = "Message Axo"
        return view
    }

    func updateUIView(_ view: AttachmentTextView, context: Context) {
        context.coordinator.parent = self
        view.pasteAttachments = pasteAttachments
        // Never reset selection/marked text during normal typing or text paste.
        if view.text != text {
            let selection = view.selectedRange
            let wasAtEnd = selection.location == view.text.utf16.count && selection.length == 0
            view.text = text
            let count = text.utf16.count
            let start = wasAtEnd ? count : min(selection.location, count)
            view.selectedRange = NSRange(location: start, length: min(selection.length, count - start))
        }
        if focused.wrappedValue && !view.isFirstResponder { view.becomeFirstResponder() }
        if !focused.wrappedValue && view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AttachmentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let height = min(line * 6, max(line, uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        return CGSize(width: width, height: ceil(height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor
        init(parent: ComposerTextEditor) { self.parent = parent }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            if view.text.isEmpty {
                parent.hasMultipleLines = false
                return
            }
            guard let font = view.font, view.bounds.width > 0 else { return }
            let measuredHeight = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
            if measuredHeight > font.lineHeight * 1.5 {
                parent.hasMultipleLines = true
            }
        }
        func textViewDidBeginEditing(_ view: UITextView) { if !parent.focused.wrappedValue { parent.focused.wrappedValue = true } }
        func textViewDidEndEditing(_ view: UITextView) { if parent.focused.wrappedValue { parent.focused.wrappedValue = false } }
    }
}

final class AttachmentTextView: UITextView {
    var pasteAttachments: (([NSItemProvider]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let board = UIPasteboard.general
            if board.hasImages || board.hasURLs || board.types.contains(where: { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
            }) { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Read payloads only for the user's actual Paste action, never on focus.
        let providers = UIPasteboard.general.itemProviders
        let attachments = providers.filter { ClipboardAttachment.kind(of: $0) != nil }
        guard !attachments.isEmpty else { super.paste(sender); return }
        pasteAttachments?(attachments)
    }
}
