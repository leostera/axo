import SwiftUI
import UIKit

/// The message box: words as a SwiftUI `TextField` would take them, and pictures pasted from the
/// clipboard, which a `TextField` ignores, attached instead. It grows with its words up to
/// `maxLines`, then scrolls.
struct ComposerTextView: UIViewRepresentable {
  @Binding var text: String
  let placeholder: String
  var enabled = true
  var maxLines = 8
  /// The pictures on the clipboard, when Paste is chosen and there are any; the words on it are
  /// left out, as on the web.
  let pastePictures: ([[String: Any]]) -> Void

  func makeUIView(context: Context) -> PastingTextView {
    let view = PastingTextView()
    view.delegate = context.coordinator
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.accessibilityIdentifier = "composer"
    return view
  }

  func updateUIView(_ view: PastingTextView, context: Context) {
    context.coordinator.parent = self
    // Only when it changed elsewhere (a slash command, dictation, a send): setting it while typing
    // moves the caret to the end and breaks marked text.
    if view.text != text { view.text = text }
    view.placeholder.text = placeholder
    view.placeholder.isHidden = !text.isEmpty
    view.isEditable = enabled
    view.pastePictures = pastePictures
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
    let width = proposal.width ?? view.bounds.width
    guard width > 0, width.isFinite else { return nil }
    let lineHeight = view.font?.lineHeight ?? 22
    let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let tallest = ceil(lineHeight * CGFloat(maxLines))
    let scrolls = fitting > tallest
    if view.isScrollEnabled != scrolls {
      // Changed on the next turn: changing it while SwiftUI sizes the view re-enters layout.
      DispatchQueue.main.async { view.isScrollEnabled = scrolls }
    }
    return CGSize(width: width, height: max(ceil(lineHeight), min(ceil(fitting), tallest)))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextView
    init(_ parent: ComposerTextView) { self.parent = parent }

    func textViewDidChange(_ view: UITextView) {
      parent.text = view.text
      (view as? PastingTextView)?.placeholder.isHidden = !view.text.isEmpty
    }
  }
}

/// A text view whose Paste attaches the clipboard's pictures.
final class PastingTextView: UITextView {
  var pastePictures: (([[String: Any]]) -> Void)?
  let placeholder = UILabel()

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    placeholder.font = .preferredFont(forTextStyle: .body)
    placeholder.adjustsFontForContentSizeCategory = true
    placeholder.textColor = .placeholderText
    placeholder.isAccessibilityElement = false
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    addSubview(placeholder)
    NSLayoutConstraint.activate([
      placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
      placeholder.topAnchor.constraint(equalTo: topAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("not from a storyboard") }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    // A picture alone on the clipboard still offers Paste.
    if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    let board = UIPasteboard.general
    if board.hasImages, let pastePictures {
      pastePictures(board.items)
      return
    }
    super.paste(sender)
  }
}
