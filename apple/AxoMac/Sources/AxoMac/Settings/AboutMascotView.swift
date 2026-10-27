import AxoMascot
import SwiftUI

/// Axo in the About pane: it watches the pointer while it is over the pane and giggles (or gets
/// annoyed) when clicked. Without the animation, the app icon.
struct AboutMascotView: View {
  /// The `Face` artboard is 1064 x 604 (`MascotBounds.face` in packages/axo-mascot).
  private static let aspectRatio = 1064.0 / 604.0
  /// The pane's coordinate space, in which the pointer and the mascot are compared.
  static let space = "about-pane"

  /// Where the pointer is over the pane, or nil.
  var pointer: CGPoint?
  /// The pane's size: half of it away is far enough to look all the way.
  var paneSize: CGSize

  @State private var puppet = AxoMascot.installedAnimation?.makePuppet(artboard: AxoMascot.Contract.faceArtboard)
  @State private var pokes = MascotPokes()
  @State private var frame: CGRect = .zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let puppet {
      puppet.view
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .frame(height: 104)
        .contentShape(Rectangle())
        .onTapGesture {
          if let reaction = pokes.poke(at: Date()) { puppet.react(reaction) }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame = $0 }
        .onChange(of: pointer) { _, pointer in follow(pointer, puppet) }
        .accessibilityElement()
        .accessibilityLabel("Axo")
        .accessibilityAddTraits(.isImage)
    } else {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
    }
  }

  private func follow(_ pointer: CGPoint?, _ puppet: any MascotPuppet) {
    guard let pointer, !reduceMotion, frame != .zero else {
      puppet.stopLooking()
      return
    }
    let reach = CGSize(width: max(paneSize.width / 2, 1), height: max(paneSize.height / 2, 1))
    puppet.look(x: (pointer.x - frame.midX) / reach.width * 100, y: (pointer.y - frame.midY) / reach.height * 100)
  }
}
