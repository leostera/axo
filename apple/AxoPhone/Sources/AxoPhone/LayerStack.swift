import AxoPhoneModel
import SwiftUI

/// Screens stacked on one another, the first at the bottom, moved by swiping the screen sideways
/// (see `LayerStackGeometry`): right to push the layer showing aside and see the one beneath,
/// left to bring it back, or, on home, to pull the next layer in over it.
///
/// Only the layer showing takes touches and VoiceOver. The strip of the layer beside it is one
/// button that brings it back, named by `edgeNames`. This view alone follows the finger: it runs
/// on every frame of a swipe, while the layers, built by its parent, are not rebuilt.
struct LayerStack: View {
  /// The layer showing.
  @Binding var showing: Int
  /// The layer that covers the ones beneath it at rest.
  let home: Int
  /// What a tap on each layer's strip does, for VoiceOver and tests: "Back to chats".
  let edgeNames: [String]
  /// Bottom first. Built by the parent, so a frame of a swipe does not rebuild them.
  let layers: [AnyView]

  /// The corners of every layer: exactly the phone screen's, so each layer is cut like the
  /// screen itself and home at rest is the screen.
  static let cornerRadius: CGFloat = DisplayCorners.radius

  @State private var dragged: CGFloat = 0
  /// The finger is moving the stack: the swipe went sideways rather than scrolling.
  @State private var swiping = false
  /// The stack is still springing to where a swipe left it.
  @State private var settling = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let _ = RenderCount.note("Layers")
    GeometryReader { geometry in
      let stack = LayerStackGeometry(count: layers.count, home: home, width: geometry.size.width)
      let position = stack.position(showing: showing, dragged: dragged)
      let edge = stack.edgeLayer(showing: showing)
      ZStack(alignment: .topLeading) {
        ForEach(layers.indices, id: \.self) { index in
          layer(layers[index], index, stack: stack, position: position, isEdge: index == edge)
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
      // What lies under the bottom layer: dark, so the rounded corners show screens on screens.
      .background(Color.black.ignoresSafeArea())
      .simultaneousGesture(swipe(stack))
    }
  }

  private func layer(
    _ content: AnyView, _ index: Int, stack: LayerStackGeometry, position: Double, isEdge: Bool
  ) -> some View {
    let moved = stack.moved(index, at: position)
    let screen = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    // A layer that cannot be seen is not drawn; it stays, with its state.
    let seen = stack.isOnScreen(index, at: position)
    return content
      // Home fills the screen; the others show beside a strip of the layer next to them.
      .frame(width: index == home ? stack.width : stack.reveal)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      // No new touch starts in a layer while the stack moves, so a tap while it springs into
      // place does not land on whatever is passing under the finger. (A touch already down is
      // not cancelled by this; rows guard against swipes with `.layerRow`.)
      .allowsHitTesting(index == showing && !swiping && !settling)
      .background(ChatColors.background.ignoresSafeArea())
      .overlay {
        Color(uiColor: .tertiarySystemBackground)
          .opacity(stack.dimming(of: index, at: position) * 0.64)
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
      // Every layer is a screen of its own, rounded like the phone's, at rest too: what is under
      // it shows at its corners and its edge, so the stack reads as screens on screens.
      .mask { screen.ignoresSafeArea() }
      .overlay {
        screen
          .stroke(Color.primary.opacity(0.1 + moved * 0.12), lineWidth: 0.5)
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
      .background {
        screen
          .fill(ChatColors.background)
          .shadow(color: .black.opacity(0.1 + moved * 0.14), radius: 16, x: index > home ? 6 : -6)
          .ignoresSafeArea()
      }
      .opacity(seen ? 1 : 0)
      .overlay(alignment: .leading) {
        if isEdge { edgeButton(for: index, stack: stack) }
      }
      .offset(x: stack.offset(of: index, at: position))
      // VoiceOver reads the layer showing only. (UI tests still find the others' elements.)
      .accessibilityHidden(index != showing)
      .zIndex(Double(index))
  }

  /// The strip of the layer beside the one showing: a tap brings that layer back. It is the
  /// visible part only, so its centre (where VoiceOver and tests tap) is on screen. Set before
  /// the layer moves, so it moves with it.
  private func edgeButton(for index: Int, stack: LayerStackGeometry) -> some View {
    // A layer pushed aside shows its left strip; the layer under one that came in shows its left
    // strip too, beside the newcomer.
    Color.clear
      .frame(width: stack.edgeWidth)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .ignoresSafeArea()
      .onTapGesture { settle(on: index, velocity: 0, stack: stack) }
      .accessibilityElement()
      .accessibilityLabel(edgeNames.indices.contains(index) ? edgeNames[index] : "Back")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { settle(on: index, velocity: 0, stack: stack) }
  }

  private func swipe(_ stack: LayerStackGeometry) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        if !swiping {
          // Sideways, clearly: a scroll that drifts is still a scroll.
          guard abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
          swiping = true
        }
        dragged = value.translation.width
      }
      .onEnded { value in
        guard swiping else { return }
        swiping = false
        let target = stack.target(showing: showing, dragged: value.translation.width, velocity: value.velocity.width)
        settle(on: target, velocity: value.velocity.width, stack: stack)
      }
  }

  /// Moves the stack to `target` with a spring that carries on at the finger's speed.
  private func settle(on target: Int, velocity: CGFloat, stack: LayerStackGeometry) {
    let from = stack.position(showing: showing, dragged: dragged)
    let distance = abs(Double(target) - from) * stack.reveal
    // Rightwards moves the stack down; a finger moving the way the stack goes keeps it going.
    let towards = (Double(target) < from) == (velocity > 0)
    let initialVelocity = distance > 1 && towards ? min(abs(velocity) / distance, 30) : 0
    let animation: Animation? = reduceMotion ? nil : .interpolatingSpring(duration: 0.42, bounce: 0.08, initialVelocity: initialVelocity)
    settling = true
    withAnimation(animation) {
      showing = target
      dragged = 0
    } completion: {
      settling = false
    }
  }
}

/// The radius of the screen's own corners. UIKit knows it, per model, but only under a private
/// key; read once. (The curve is Apple's continuous one, which `.continuous` draws.) Screens
/// without rounded corners report 0, and a missing key falls back to a recent iPhone's.
enum DisplayCorners {
  static let radius: CGFloat = {
    let value = UIScreen.main.value(forKey: ["Radius", "Corner", "display", "_"].reversed().joined()) as? CGFloat
    return value ?? 55
  }()
}

/// A row as wide as its layer, chosen with a tap and only a tap. A `Button` acts when the finger
/// lifts anywhere inside it, so a sideways swipe that starts on a full-width row and moves the
/// stack would also open that row; a tap fails once the finger moves. Still a button to VoiceOver.
struct LayerRowButtonStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onTapGesture { configuration.trigger() }
  }
}

extension PrimitiveButtonStyle where Self == LayerRowButtonStyle {
  static var layerRow: LayerRowButtonStyle { LayerRowButtonStyle() }
}
