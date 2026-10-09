/// Reading intent changes through user scrolling or an explicit latest jump,
/// never because streaming text, keyboard layout, or page insertion grows content.
public struct ConversationScrollState: Equatable, Sendable {
    public private(set) var followsLatest = true
    public private(set) var hasNewMessages = false

    public init() {}

    public mutating func userScrolled(isAtLatest: Bool) {
        followsLatest = isAtLatest
        if isAtLatest { hasNewMessages = false }
    }

    public mutating func latestMessageChanged(from previousID: String?, to nextID: String?) {
        guard !followsLatest, let previousID, let nextID, previousID != nextID else { return }
        hasNewMessages = true
    }

    public mutating func jumpToLatest() {
        followsLatest = true
        hasNewMessages = false
    }
}
