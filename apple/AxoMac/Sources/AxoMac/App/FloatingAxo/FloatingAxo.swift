import AppKit
import AxoMascot
import Observation
import SpriteKit
import SwiftUI

/// The Axos pulled out of the menu bar. The menu bar's Axo is rubber: pulled far enough it pops
/// (`RubberAxo`), leaving a new, same-sized Axo under the pointer, and it can be done again and
/// again. Each Axo out is its own `FloatingAxo`, to be picked up, thrown and poked on its own;
/// dropping one on the menu bar icon (or "Put Axos Away") puts it back.
@MainActor
@Observable
final class FloatingAxos {
  static let shared = FloatingAxos()

  /// Every Axo out on the screen.
  private(set) var axos: [FloatingAxo] = []
  /// While the rubber Axo is drawn over it, the menu bar's own icon is hidden.
  private(set) var menuBarIconHidden = false
  /// Where the menu bar icon is, in screen coordinates; dropping an Axo there puts it away.
  @ObservationIgnored var home: () -> CGRect? = { nil }
  /// The menu bar's Axo image now (a template image), and the menu bar's appearance, to draw the
  /// rubber one as the menu bar does.
  @ObservationIgnored var mark: () -> NSImage? = { nil }
  @ObservationIgnored var menuBarAppearance: () -> NSAppearance? = { nil }

  /// The menu bar's Axo, stretched by the pointer, until it pops.
  @ObservationIgnored private var rubber: RubberAxo?
  /// Rubber Axos still drawn: the one pulled now, and any still springing back.
  @ObservationIgnored private var rubbersOut = 0 {
    didSet { menuBarIconHidden = rubbersOut > 0 }
  }
  /// The Axo that popped out under the pointer, still held by the drag that pulled it out.
  @ObservationIgnored private weak var plucked: FloatingAxo?
  @ObservationIgnored private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private init() {}

  // MARK: Pulled out of the menu bar

  /// The pointer pulled the menu bar's Axo at `point`: it stretches, rubbery, until it pops and a
  /// new Axo comes away under the pointer, or springs back if let go first. With Reduce Motion
  /// the new Axo just comes out.
  func pluck(at point: CGPoint) {
    guard rubber == nil else { return }
    guard !reduceMotion, let window = home(), let image = tintedMark() else { return popOut(at: point, pull: .zero) }
    let size = FloatingAxo.size
    let icon = CGRect(x: window.midX - size.width / 2, y: window.midY - size.height / 2, width: size.width, height: size.height)
    guard let rubber = RubberAxo(icon: icon, image: image, grab: point) else { return popOut(at: point, pull: .zero) }
    rubber.onPop = { [weak self, weak rubber] in self?.popOut(at: NSEvent.mouseLocation, pull: rubber?.pull ?? .zero) }
    rubber.onRest = { [weak self] in self?.rubbersOut -= 1 }
    self.rubber = rubber
    rubbersOut += 1
  }

  func drag(to point: CGPoint) {
    if let rubber { return rubber.move(to: point) }
    plucked?.drag(to: point)
  }

  func letGo(at point: CGPoint) {
    if let rubber {
      rubber.letGo()
      self.rubber = nil
      return
    }
    plucked?.letGo(at: point)
    plucked = nil
  }

  /// A new Axo, under the pointer, held by the drag that pulled it out.
  private func popOut(at point: CGPoint, pull: CGVector) {
    rubber = nil
    guard let axo = FloatingAxo(at: point, keeper: self) else { return }
    axos.append(axo)
    plucked = axo
    axo.popped(pull: pull)
  }

  // MARK: Put away

  /// Dropped at `point`: on the menu bar icon, it goes back in.
  func isHome(_ point: CGPoint) -> Bool {
    home()?.insetBy(dx: -12, dy: -12).contains(point) ?? false
  }

  func putAway(_ axo: FloatingAxo) {
    axos.removeAll { $0 === axo }
    axo.vanish()
  }

  func putAllAway() {
    axos.forEach { $0.vanish() }
    axos.removeAll()
  }

  /// The menu bar's Axo in the colour the menu bar draws it, sharp enough to stretch.
  private func tintedMark() -> CGImage? {
    guard let mark = mark()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var color = NSColor.black.cgColor
    (menuBarAppearance() ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
      color = NSColor.labelColor.withAlphaComponent(1).cgColor
    }
    let width = mark.width, height = mark.height
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(mark, in: rect)
    // A template image: its shape, in the menu bar's colour.
    context.setBlendMode(.sourceIn)
    context.setFillColor(color)
    context.fill(rect)
    return context.makeImage()
  }
}

/// One Axo out on the screen: a little floating panel that can be thrown around and lands on the
/// screen's edges and on the tops of windows, with its own face, physics and pokes.
///
/// The physics is SpriteKit's (`FloatingAxoWorld`), in screen coordinates; the panel follows the
/// body each frame. With Reduce Motion on it stays where it is dropped.
@MainActor
final class FloatingAxo {
  /// Axo's size on screen: the menu bar's, since it is another one of those.
  static let size = AxoMascot.menuBarSize
  /// Square and larger than Axo, so it can turn and stretch inside it.
  static let panelSide: CGFloat = 48
  /// Throws faster than this are frightening.
  static let screamingSpeed: CGFloat = 1800

  private unowned let keeper: FloatingAxos
  private let panel: NSPanel
  private let world: FloatingAxoWorld
  private let puppet: any MascotPuppet
  private let pose = FloatingAxoPose()
  private var pokes = MascotPokes()
  private var velocity = ThrowVelocity()
  /// Where on Axo it is held, from its centre.
  private var grip: CGVector = .zero
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  init?(at point: CGPoint, keeper: FloatingAxos) {
    guard let puppet = AxoMascot.installedAnimation?.makePuppet(artboard: AxoMascot.Contract.faceArtboard) else { return nil }
    self.keeper = keeper
    self.puppet = puppet
    world = FloatingAxoWorld(start: point, bodySize: Self.size)
    let side = Self.panelSide
    panel = FloatingAxoPanel(contentRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    world.onStep = { [weak self] in self?.follow() }
    world.onLanded = { [weak self] impulse in self?.landed(impulse) }
    world.onSettled = { [weak self] in self?.puppet.react(.happy) }

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
    handle.axo = self
    content.addSubview(handle)
    panel.contentView = content
    panel.orderFrontRegardless()
  }

  /// Just popped out of the menu bar's Axo, pulled along `pull`: it boings into shape after the
  /// stretch and giggles, held where it is.
  func popped(pull: CGVector) {
    grip = .zero
    velocity.reset()
    world.hold(at: world.axoPosition)
    pose.stretch = 0.3
    pose.stretchAngle = .radians(atan2(-pull.dy, pull.dx))
    pose.boing()
    puppet.react(.giggle)
  }

  // MARK: Held

  /// The pointer picked it up at `point`.
  func grab(at point: CGPoint) {
    grip = CGVector(dx: point.x - world.axoPosition.x, dy: point.y - world.axoPosition.y)
    velocity.reset()
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world.hold(at: world.axoPosition)
  }

  func drag(to point: CGPoint) {
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world.hold(at: CGPoint(x: point.x - grip.dx, y: point.y - grip.dy))
  }

  func letGo(at point: CGPoint) {
    if keeper.isHome(point) { return keeper.putAway(self) }
    let throwing = reduceMotion ? .zero : velocity.velocity(at: ProcessInfo.processInfo.systemUptime)
    world.letGo(velocity: throwing, freeze: reduceMotion)
    if hypot(throwing.dx, throwing.dy) > Self.screamingSpeed { puppet.react(.scream) }
  }

  /// A click on it, not a drag: it is poked.
  func poke() {
    if let reaction = pokes.poke(at: Date()) { puppet.react(reaction) }
  }

  /// Gone: back in the menu bar.
  func vanish() {
    world.isPaused = true
    let panel = panel
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in panel.orderOut(nil) }
    }
  }

  // MARK: Each frame

  private func follow() {
    let side = Self.panelSide
    panel.setFrameOrigin(CGPoint(x: world.axoPosition.x - side / 2, y: world.axoPosition.y - side / 2))
    pose.rotation = world.axoRotation
    // Watch the pointer, from Axo's centre; 400 points away is all the way.
    let pointer = NSEvent.mouseLocation
    puppet.look(x: (pointer.x - world.axoPosition.x) / 4, y: -(pointer.y - world.axoPosition.y) / 4)
  }

  private func landed(_ impulse: CGFloat) {
    guard impulse > 1.5, !reduceMotion else { return }
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
  /// Stretched along `stretchAngle` by this much (0.2 is a fifth longer), and thinner across.
  var stretch: CGFloat = 0
  /// SwiftUI's: clockwise from the right, since its y is down.
  var stretchAngle: Angle = .zero

  /// Popped out of the menu bar's Axo: back into shape on a loose spring, wobbling past it.
  func boing() {
    withAnimation(.interpolatingSpring(stiffness: 260, damping: 6)) { stretch = 0 }
  }

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
      // Stretched along the pull: turned to it, stretched across x, turned back.
      .rotationEffect(-pose.stretchAngle)
      .scaleEffect(x: 1 + pose.stretch, y: 1 / (1 + pose.stretch))
      .rotationEffect(pose.stretchAngle)
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
  weak var axo: FloatingAxo?
  private var pressedAt: CGPoint?
  private var dragging = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Only Axo itself, not the panel's empty corners.
    let local = convert(point, from: superview)
    let axo = CGRect(
      x: bounds.midX - FloatingAxo.size.width / 2, y: bounds.midY - FloatingAxo.size.height / 2,
      width: FloatingAxo.size.width, height: FloatingAxo.size.height)
    // Axo is small: a little slack around it.
    return axo.insetBy(dx: -6, dy: -6).contains(local) ? self : nil
  }

  override func mouseDown(with event: NSEvent) {
    pressedAt = NSEvent.mouseLocation
    dragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    let point = NSEvent.mouseLocation
    if !dragging, let pressedAt, DragThreshold.isDrag(from: pressedAt, to: point) {
      dragging = true
      axo?.grab(at: pressedAt)
    }
    if dragging { axo?.drag(to: point) }
  }

  override func mouseUp(with event: NSEvent) {
    if dragging {
      axo?.letGo(at: NSEvent.mouseLocation)
    } else {
      axo?.poke()
    }
    pressedAt = nil
    dragging = false
  }
}
