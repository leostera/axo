import AppKit

/// Empty identity leaf for the pinned tree. Decoding geometry cannot launch or
/// attach a terminal; the presentation layer uses committed runtime snapshots.
final class AxodPaneLayoutLeaf: NSView, Codable, Identifiable {
    let id: UUID
    init(id: UUID) { self.id = id; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Programmatic layout identity") }
    required init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(UUID.self)
        super.init(frame: .zero)
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(id)
    }
}
