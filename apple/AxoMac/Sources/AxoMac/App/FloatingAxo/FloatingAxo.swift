import AppKit
import AxoMascot
import Observation
import SpriteKit
import SwiftUI

/// Axo, dragged out of the menu bar: a little floating panel that can be thrown around the
/// screen and lands on the screen's edges and on the tops of windows.
///
/// The physics is SpriteKit's (`FloatingAxoWorld`), in screen coordinates; the panel follows
/// the body each frame. Drag it back onto the menu bar icon (or choose "Put Axo Away") to put
/// it back. With Reduce Motion on it stays where it is dropped.
@MainActor
@Observable
final class FloatingAxo {
  static let shared = FloatingAxo()

  /// Axo's size on screen: the `Face` artboard's shape (1064 x 604).
  static let size = CGSize(width: 96, height: 96 * 604 / 1064)
  /// Square and larger than Axo, so it can turn inside it.
  static let panelSide: CGFloat = 124
  /// Throws faster than this are frightening.
  static let screamingSpeed: CGFloat = 1800

  private(set) var isOut = false
  /// Where the menu bar icon is, in screen coordinates; dropping Axo there puts it away.
  @ObservationIgnored var home: () -> CGRect? = { nil }

  @ObservationIgnored private var panel: NSPanel?
  @ObservationIgnored private var world: FloatingAxoWorld?
  @ObservationIgnored private var puppet: (any MascotPuppet)?
  @ObservationIgnored private let pose = FloatingAxoPose()
  @ObservationIgnored private var pokes = MascotPokes()
  @ObservationIgnored private var velocity = ThrowVelocity()
  /// Where on Axo it is held, from its centre.
  @ObservationIgnored private var grip: CGVector = .zero
  @ObservationIgnored private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private init() {}

  // MARK: Held

  /// The pointer picked Axo up at `point` (from the menu bar, or off the screen).
  func grab(at point: CGPoint) {
    if !isOut { takeOut(at: point) }
    guard let world else { return }
    grip = CGVector(dx: point.x - world.axoPosition.x, dy: point.y - world.axoPosition.y)
    velocity.reset()
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world.hold(at: world.axoPosition)
  }

  func drag(to point: CGPoint) {
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world?.hold(at: CGPoint(x: point.x - grip.dx, y: point.y - grip.dy))
  }

  func letGo(at point: CGPoint) {
    if let home = home(), home.insetBy(dx: -12, dy: -12).contains(point) {
      putAway()
      return
    }
    let throwing = reduceMotion ? .zero : velocity.velocity(at: ProcessInfo.processInfo.systemUptime)
    world?.letGo(velocity: throwing, freeze: reduceMotion)
    if hypot(throwing.dx, throwing.dy) > Self.screamingSpeed { puppet?.react(.scream) }
  }

  /// A click on Axo, not a drag: it is poked.
  func poke() {
    if let reaction = pokes.poke(at: Date()) { puppet?.react(reaction) }
  }

  // MARK: Out and back

  private func takeOut(at point: CGPoint) {
    guard let puppet = AxoMascot.installedAnimation?.makePuppet(artboard: AxoMascot.Contract.faceArtboard) else { return }
    self.puppet = puppet
    let world = FloatingAxoWorld(start: point, bodySize: Self.size)
    world.onStep = { [weak self] in self?.follow() }
    world.onLanded = { [weak self] impulse in self?.landed(impulse) }
    world.onSettled = { [weak self] in self?.puppet?.react(.happy) }
    self.world = world

    let side = Self.panelSide
    let panel = FloatingAxoPanel(contentRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    let content = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    // The physics' clock: an SKView presenting the world; it draws nothing.
    let clock = SKView(frame: content.bounds)
    clock.allowsTransparency = true
    clock.autoresizingMask = [.width, .height]
    clock.presentScene(world)
    content.addSubview(clock)
    let face = NSHostingView(rootView: FloatingAxoFace(puppet: puppet, pose: pose))
    face.frame = content.bounds
    face.autoresizingMask = [.width, .height]
    content.addSubview(face)
    let handle = FloatingAxoHandle(frame: content.bounds)
    handle.autoresizingMask = [.width, .height]
    content.addSubview(handle)
    panel.contentView = content
    panel.orderFrontRegardless()
    self.panel = panel
    isOut = true
  }

  func putAway() {
    guard let panel else { return }
    isOut = false
    world?.isPaused = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in
        panel.orderOut(nil)
        self.panel = nil
        self.world = nil
        self.puppet = nil
      }
    }
  }

  // MARK: Each frame

  private func follow() {
    guard let world, let panel else { return }
    let side = Self.panelSide
    panel.setFrameOrigin(CGPoint(x: world.axoPosition.x - side / 2, y: world.axoPosition.y - side / 2))
    pose.rotation = world.axoRotation
    // Watch the pointer, from Axo's centre; 400 points away is all the way.
    let pointer = NSEvent.mouseLocation
    puppet?.look(x: (pointer.x - world.axoPosition.x) / 4, y: -(pointer.y - world.axoPosition.y) / 4)
  }

  private func landed(_ impulse: CGFloat) {
    guard impulse > 18, !reduceMotion else { return }
    pose.squish()
  }
}

/// What the physics says about how Axo is lying, for its view.
@MainActor
@Observable
final class FloatingAxoPose {
  /// Radians, counterclockwise (SpriteKit's).
  var rotation: CGFloat = 0
  var squished = false

  /// Touching down: squish for a couple of frames, then back.
  func squish() {
    withAnimation(.linear(duration: 0.035)) { squished = true }
    Task {
      try? await Task.sleep(for: .milliseconds(35))
      withAnimation(.easeOut(duration: 0.09)) { squished = false }
    }
  }
}

private struct FloatingAxoFace: View {
  let puppet: any MascotPuppet
  let pose: FloatingAxoPose

  var body: some View {
    puppet.view
      .frame(width: FloatingAxo.size.width, height: FloatingAxo.size.height)
      .scaleEffect(x: pose.squished ? 1.06 : 1, y: pose.squished ? 0.92 : 1, anchor: .bottom)
      .rotationEffect(.radians(-pose.rotation))
      .frame(width: FloatingAxo.panelSide, height: FloatingAxo.panelSide)
      .accessibilityElement()
      .accessibilityLabel("Axo")
  }
}

/// A borderless, see-through panel above other windows that never takes focus.
private final class FloatingAxoPanel: NSPanel {
  init(contentRect: CGRect) {
    super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    isRestorable = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Takes the pointer over the panel: a press that moves is a grab, one that does not is a poke.
private final class FloatingAxoHandle: NSView {
  private var pressedAt: CGPoint?
  private var dragging = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Only Axo itself, not the panel's empty corners.
    let local = convert(point, from: superview)
    let axo = CGRect(
      x: bounds.midX - FloatingAxo.size.width / 2, y: bounds.midY - FloatingAxo.size.height / 2,
      width: FloatingAxo.size.width, height: FloatingAxo.size.height)
    return axo.contains(local) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    pressedAt = NSEvent.mouseLocation
    dragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    let point = NSEvent.mouseLocation
    if !dragging, let pressedAt, DragThreshold.isDrag(from: pressedAt, to: point) {
      dragging = true
      FloatingAxo.shared.grab(at: pressedAt)
    }
    if dragging { FloatingAxo.shared.drag(to: point) }
  }

  override func mouseUp(with event: NSEvent) {
    if dragging {
      FloatingAxo.shared.letGo(at: NSEvent.mouseLocation)
    } else {
      FloatingAxo.shared.poke()
    }
    pressedAt = nil
    dragging = false
  }
}
