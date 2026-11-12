import SwiftUI

/// The real mascot's Mark geometry as native paths. Accent color applies only to the ink,
/// avoiding bitmap/template redaction and rectangular image masks in watch complications.
public struct AxoMascotMark: Shape {
  public init() {}

  public func path(in rect: CGRect) -> Path {
    guard rect.width > 0, rect.height > 0 else { return Path() }
    let bounds = AxoMascotGeometry.bounds
    let scale = min(rect.width / bounds.width, rect.height / bounds.height)
    let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
      tx: rect.midX - bounds.midX * scale, ty: rect.midY - bounds.midY * scale)
    return AxoMascotGeometry.ink.applying(transform)
  }
}
