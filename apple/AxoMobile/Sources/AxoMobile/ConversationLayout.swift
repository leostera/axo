import Foundation

/// The transcript and composer share one centered envelope, including their inner side padding.
enum ConversationLayout {
  static let columnWidth: CGFloat = 800
  static let sidePadding: CGFloat = 20

  static func rowInset(in width: CGFloat) -> CGFloat {
    max(sidePadding, (width - columnWidth) / 2 + sidePadding)
  }
}
