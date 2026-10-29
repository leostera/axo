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

  /// A squishy 3D Axo (`SquishyAxoView`), dropped from just under the menu bar icon (or the top
  /// of the screen), to try it out alongside the flat ones.
  func dropSquishy() {
    let screen = NSScreen.main?.visibleFrame ?? .zero
    let at = home().map { CGPoint(x: $0.midX, y: $0.minY - 60) } ?? CGPoint(x: screen.midX, y: screen.maxY - 60)
    guard let axo = FloatingAxo(at: at, keeper: self, kind: .squishy) else { return }
    axos.append(axo)
    axo.letGo(at: at)
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

  func burst(_ axo: FloatingAxo) {
    axos.removeAll { $0 === axo }
    axo.explode()
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
  /// How it is drawn.
  enum Kind {
    /// The menu bar's Axo, flat (Rive).
    case flat
    /// A squishy 3D one: a cel-shaded soft body (`SquishyAxoView`).
    case squishy
  }

  /// Axo's size on screen: the menu bar's, since it is another one of those.
  static let size = AxoMascot.menuBarSize
  /// Square and larger than Axo, so it can turn, stretch and blow up inside it.
  static let panelSide: CGFloat = 88
  /// The squishy one is bigger, to see its face and how it squishes.
  static let squishyWidth: CGFloat = 76

  /// This one's size, and its panel's side.
  let size: CGSize
  private let panelSide: CGFloat
  /// Throws faster than this are frightening.
  static let screamingSpeed: CGFloat = 1800
  /// Left alone this long, it fades away over `fadeAway`; touching it brings it back.
  static let lifetime: Duration = .seconds(20)
  static let fadeAway: TimeInterval = 1.5

  private unowned let keeper: FloatingAxos
  private let panel: NSPanel
  private let world: FloatingAxoWorld
  /// The flat one's face, or the squishy one.
  private let puppet: (any MascotPuppet)?
  private let squishy: SquishyAxoView?
  private let pose = FloatingAxoPose()
  /// Its velocity at the last frame, in points a second: what a landing stops, and what changes
  /// in a drag jolt the squishy one.
  private var lastPosition: CGPoint?
  private var lastVelocity: CGVector = .zero
  private var lastStep: CFTimeInterval?
  private var pokes = MascotPokes()
  private var inflation = Inflation()
  /// How big its physics body is, which follows how blown up it is, in steps.
  private var bodyScale: CGFloat = 1
  private var velocity = ThrowVelocity()
  /// Where on Axo it is held, from its centre.
  private var grip: CGVector = .zero
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  /// Counting down to fading away, while it is left alone.
  private var lonely: Task<Void, Never>?

  init?(at point: CGPoint, keeper: FloatingAxos, kind: Kind = .flat) {
    switch kind {
    case .flat:
      guard let puppet = AxoMascot.installedAnimation?.makePuppet(artboard: AxoMascot.Contract.faceArtboard) else { return nil }
      self.puppet = puppet
      squishy = nil
      size = Self.size
      panelSide = Self.panelSide
    case .squishy:
      size = SquishyAxoView.size(width: Self.squishyWidth)
      // Room to turn, stretch and blow up (up to `Inflation.biggest`) in.
      panelSide = (Self.squishyWidth * 2.4).rounded()
      guard let view = SquishyAxoView(frame: CGRect(x: 0, y: 0, width: panelSide, height: panelSide), width: Self.squishyWidth)
      else { return nil }
      squishy = view
      puppet = nil
    }
    self.keeper = keeper
    // The squishy one's body is its head: its gills are soft.
    world = FloatingAxoWorld(start: point, bodySize: squishy == nil ? size : CGSize(width: size.width * 0.75, height: size.height * 0.8))
    let side = panelSide
    panel = FloatingAxoPanel(contentRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
    world.onStep = { [weak self] in self?.follow() }
    world.onLanded = { [weak self] impulse in self?.landed(impulse) }
    world.onSettled = { [weak self] in self?.react(.happy) }

    let content = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    // The physics' clock: an SKView presenting the world; it draws nothing.
    let clock = SKView(frame: content.bounds)
    clock.allowsTransparency = true
    clock.autoresizingMask = [.width, .height]
    clock.presentScene(world)
    content.addSubview(clock)
    if let puppet {
      let face = NSHostingView(rootView: FloatingAxoFace(puppet: puppet, pose: pose))
      face.frame = content.bounds
      face.autoresizingMask = [.width, .height]
      content.addSubview(face)
    }
    if let squishy {
      squishy.autoresizingMask = [.width, .height]
      content.addSubview(squishy)
    }
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
    react(.giggle)
  }

  private func react(_ reaction: MascotReaction) {
    puppet?.react(reaction)
    squishy?.react(reaction)
  }

  private func setSqueezed(_ squeezed: Bool) {
    puppet?.setSqueezed(squeezed)
    squishy?.setSqueezed(squeezed)
  }

  // MARK: Held

  /// The pointer picked it up at `point`.
  func grab(at point: CGPoint) {
    stayAround()
    grip = CGVector(dx: point.x - world.axoPosition.x, dy: point.y - world.axoPosition.y)
    velocity.reset()
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world.hold(at: world.axoPosition)
    squishy?.lift()
    squishy?.grab(at: CGPoint(x: grip.dx, y: grip.dy))
  }

  func drag(to point: CGPoint) {
    velocity.add(point, at: ProcessInfo.processInfo.systemUptime)
    world.hold(at: CGPoint(x: point.x - grip.dx, y: point.y - grip.dy))
  }

  func letGo(at point: CGPoint) {
    // Off the ground until it lands.
    squishy?.letGo()
    squishy?.lift()
    if keeper.isHome(point) { return keeper.putAway(self) }
    startLonely()
    let throwing = reduceMotion ? .zero : velocity.velocity(at: ProcessInfo.processInfo.systemUptime)
    world.letGo(velocity: throwing, freeze: reduceMotion)
    if hypot(throwing.dx, throwing.dy) > Self.screamingSpeed { react(.scream) }
  }

  /// A click on it, not a drag: it is poked.
  /// Each one blows it up a little more; enough in a row, and it bursts.
  func poke() {
    let now = Date()
    let (fullness, bursts) = inflation.poke(at: now)
    if bursts { return keeper.burst(self) }
    startLonely()
    if let reaction = pokes.poke(at: now) { react(reaction) }
    if !reduceMotion, let squishy {
      let pointer = NSEvent.mouseLocation
      squishy.poke(at: CGPoint(x: pointer.x - world.axoPosition.x, y: pointer.y - world.axoPosition.y))
    }
    // Straining, eyes squeezed shut, as it gets near.
    if fullness > 0.65 { setSqueezed(true) }
    inflate(at: now)
  }

  /// How much bigger than itself it is now, for grabbing it.
  var scale: CGFloat { pose.inflation }

  /// Blown up as `inflation` says now: its look, and its body when that has moved on enough.
  private func inflate(at now: Date) {
    let scale = inflation.scale(at: now)
    if abs(scale - pose.inflation) > 0.005 {
      if let squishy {
        // Its own air blows it up, and lets it down.
        pose.inflation = scale
        squishy.inflate(scale)
      } else {
        withAnimation(.interpolatingSpring(stiffness: 400, damping: 14)) { pose.inflation = scale }
      }
    }
    if abs(scale - bodyScale) > 0.08 || (scale == 1 && bodyScale != 1) {
      bodyScale = scale
      world.resize(to: scale)
    }
    if inflation.fullness(at: now) < 0.6 { setSqueezed(false) }
  }

  /// Burst: it is gone in a spray of bits.
  func explode() {
    lonely?.cancel()
    world.isPaused = true
    panel.orderOut(nil)
    if !reduceMotion { AxoBurst.spray(at: world.axoPosition, size: size.applying(.init(scaleX: scale, y: scale))) }
  }

  /// Gone: back in the menu bar.
  func vanish() {
    lonely?.cancel()
    world.isPaused = true
    let panel = panel
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in panel.orderOut(nil) }
    }
  }

  // MARK: Left alone

  /// Touched: no fading, and back in full if it had started to.
  private func stayAround() {
    lonely?.cancel()
    lonely = nil
    if panel.alphaValue < 1 { fade(to: 1, over: 0.15) }
  }

  /// Let go: from now, left alone for `lifetime`, it fades away and is gone.
  private func startLonely() {
    stayAround()
    lonely = Task { [weak self] in
      try? await Task.sleep(for: Self.lifetime)
      guard !Task.isCancelled, let self else { return }
      self.fade(to: 0, over: Self.fadeAway)
      try? await Task.sleep(for: .seconds(Self.fadeAway))
      guard !Task.isCancelled else { return }
      self.keeper.putAway(self)
    }
  }

  private func fade(to alpha: CGFloat, over seconds: TimeInterval) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = seconds
      panel.animator().alphaValue = alpha
    }
  }

  // MARK: Each frame

  private func follow() {
    let side = panelSide
    let position = world.axoPosition
    panel.setFrameOrigin(CGPoint(x: position.x - side / 2, y: position.y - side / 2))
    pose.rotation = world.axoRotation
    // How fast it is going, and how much that changed: the squishy one lags behind changes.
    let now = CACurrentMediaTime()
    if let lastPosition, let lastStep, now - lastStep > 0.001 {
      let seconds = now - lastStep
      let velocity = CGVector(dx: (position.x - lastPosition.x) / seconds, dy: (position.y - lastPosition.y) / seconds)
      if !reduceMotion { squishy?.jolt(CGVector(dx: velocity.dx - lastVelocity.dx, dy: velocity.dy - lastVelocity.dy)) }
      lastVelocity = velocity
    }
    lastPosition = position
    lastStep = now
    // The air leaking out.
    if pose.inflation > 1 { inflate(at: Date()) }
    // Watch the pointer, from Axo's centre; 400 points away is all the way.
    let pointer = NSEvent.mouseLocation
    puppet?.look(x: (pointer.x - position.x) / 4, y: -(pointer.y - position.y) / 4)
    if let squishy {
      squishy.roll = world.axoRotation
      squishy.look = CGPoint(x: max(-1, min(1, (pointer.x - position.x) / 400)), y: max(-1, min(1, (pointer.y - position.y) / 400)))
    }
  }

  private func landed(_ impulse: CGFloat) {
    guard impulse > 1.5, !reduceMotion else { return }
    guard let squishy else { return pose.squish() }
    // Its window just stopped; it keeps going, from as fast as it was falling.
    squishy.land(speed: min(1500, max(0, -lastVelocity.dy)))
  }
}

/// What the physics says about how Axo is lying, for its view.
@MainActor
@Observable
final class FloatingAxoPose {
  /// Radians, counterclockwise (SpriteKit's).
  var rotation: CGFloat = 0
  var squished = false
  /// Blown up this many times its size by clicking.
  var inflation: CGFloat = 1
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
      .scaleEffect(pose.inflation)
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
    let size = self.axo?.size ?? FloatingAxo.size
    let axo = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    // Axo is small: a little slack around it. Blown up, it is bigger.
    let scale = self.axo?.scale ?? 1
    let grown = axo.insetBy(dx: -axo.width * (scale - 1) / 2, dy: -axo.height * (scale - 1) / 2)
    return grown.insetBy(dx: -6, dy: -6).contains(local) ? self : nil
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
