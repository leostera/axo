import AxoMascot
import SwiftUI

/// The squishy 3D Axo (`SquishyAxoView`) in the About pane, sitting on the ground, to try out:
/// it watches the pointer, dents and giggles when clicked (annoyed after a few), and stretches
/// after the pointer when dragged, wobbling back when let go. With Reduce Motion it only watches
/// and reacts.
struct AboutSquishyView: View {
  /// Room around it to stretch in.
  static let size = CGSize(width: 340, height: 220)
  static let width: CGFloat = 130

  var pointer: CGPoint?
  var paneSize: CGSize

  /// Made once it is shown (SwiftUI would make a `@State`'s first value each time it remakes
  /// this view, and this one is a Metal view and a physics body).
  @State private var squishy: SquishyAxoView?
  @State private var pokes = MascotPokes()
  @State private var frame: CGRect = .zero
  @State private var holding = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    content
      .frame(width: Self.size.width, height: Self.size.height)
      .onAppear {
        guard squishy == nil, let view = SquishyAxoView(frame: CGRect(origin: .zero, size: Self.size), width: Self.width)
        else { return }
        // Sitting on the bottom of its space.
        view.sit()
        squishy = view
      }
  }

  @ViewBuilder private var content: some View {
    if let squishy {
      SquishyAxoRepresentable(view: squishy)
        .overlay {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { location in
              if !reduceMotion { squishy.poke(at: centred(location)) }
              if let reaction = pokes.poke(at: Date()) { squishy.react(reaction) }
            }
            .simultaneousGesture(
              DragGesture(minimumDistance: 4)
                .onChanged { drag in
                  guard !reduceMotion else { return }
                  if !holding {
                    holding = true
                    squishy.grab(at: centred(drag.startLocation))
                  }
                  squishy.pull(to: centred(drag.location))
                }
                .onEnded { _ in
                  holding = false
                  squishy.letGo()
                }
            )
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AboutMascotView.space)) } action: { frame = $0 }
        .onChange(of: pointer) { _, pointer in follow(pointer, squishy) }
        .accessibilityElement()
        .accessibilityLabel("Squishy Axo")
        .accessibilityAddTraits(.isImage)
    }
  }

  /// A point in this view (SwiftUI's: from its top left, y down) from its middle, y up.
  private func centred(_ location: CGPoint) -> CGPoint {
    CGPoint(x: location.x - Self.size.width / 2, y: Self.size.height / 2 - location.y)
  }

  private func follow(_ pointer: CGPoint?, _ squishy: SquishyAxoView) {
    guard let pointer, frame != .zero else {
      squishy.look = .zero
      return
    }
    let reach = CGSize(width: max(paneSize.width / 2, 1), height: max(paneSize.height / 2, 1))
    squishy.look = CGPoint(
      x: max(-1, min(1, (pointer.x - frame.midX) / reach.width)),
      y: max(-1, min(1, -(pointer.y - frame.midY) / reach.height)))
  }
}

private struct SquishyAxoRepresentable: NSViewRepresentable {
  let view: SquishyAxoView

  func makeNSView(context: Context) -> SquishyAxoView { view }
  func updateNSView(_ nsView: SquishyAxoView, context: Context) {}
}
