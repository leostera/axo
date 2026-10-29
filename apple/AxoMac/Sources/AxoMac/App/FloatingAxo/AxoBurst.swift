import AppKit

/// An Axo bursting: a spray of bits of it, white and ink, flung out and falling, in a moment.
@MainActor
enum AxoBurst {
  private static let lasts: TimeInterval = 1.1

  /// Bursts an Axo of `size`, centred at `point` (screen points).
  static func spray(at point: CGPoint, size: CGSize) {
    let side: CGFloat = 420
    let panel = NSPanel(
      contentRect: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isRestorable = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let view = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
    view.wantsLayer = true
    let emitter = CAEmitterLayer()
    emitter.frame = view.bounds
    emitter.emitterPosition = CGPoint(x: side / 2, y: side / 2)
    emitter.emitterShape = .rectangle
    emitter.emitterSize = size
    emitter.emitterCells = [bit(face: true), bit(face: false)]
    emitter.beginTime = CACurrentMediaTime()
    view.layer?.addSublayer(emitter)
    panel.contentView = view
    panel.orderFrontRegardless()
    // One puff of bits, then none.
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(60))
      emitter.birthRate = 0
      try? await Task.sleep(for: .seconds(lasts))
      panel.orderOut(nil)
    }
  }

  /// A bit of Axo: white with its ink outline, or a fleck of ink.
  private static func bit(face: Bool) -> CAEmitterCell {
    let cell = CAEmitterCell()
    cell.contents = dot(face: face)
    cell.birthRate = face ? 500 : 260
    cell.lifetime = Float(lasts)
    cell.velocity = 300
    cell.velocityRange = 160
    cell.emissionRange = .pi * 2
    // Falling: y is up in this layer.
    cell.yAcceleration = -900
    cell.scale = face ? 0.85 : 0.5
    cell.scaleRange = 0.35
    cell.scaleSpeed = -0.3
    cell.spinRange = 8
    cell.alphaSpeed = -0.6
    return cell
  }

  private static func dot(face: Bool) -> CGImage? {
    let side = 16
    guard let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let ink = CGColor(srgbRed: 0x1f / 255, green: 0x1f / 255, blue: 0x1f / 255, alpha: 1)
    let rect = CGRect(x: 2, y: 2, width: side - 4, height: side - 4)
    if face {
      context.setFillColor(CGColor(srgbRed: 0xfb / 255, green: 0xfb / 255, blue: 0xfb / 255, alpha: 1))
      context.fillEllipse(in: rect)
      context.setStrokeColor(ink)
      context.setLineWidth(2.5)
      context.strokeEllipse(in: rect)
    } else {
      context.setFillColor(ink)
      context.fillEllipse(in: rect)
    }
    return context.makeImage()
  }
}
