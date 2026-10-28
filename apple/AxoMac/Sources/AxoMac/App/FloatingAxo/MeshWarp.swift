import CoreGraphics

/// Draws an image bent over a grid: the image's rectangle is cut into the grid's cells, two
/// triangles each, and each triangle is drawn where the grid's points now are.
enum MeshWarp {
  /// Draws `image`, `size` points (y up), over the `columns` x `rows` grid of `points` (row by row
  /// from the bottom left; at rest they spread evenly over `size`).
  static func draw(_ image: CGImage, size: CGSize, columns: Int, rows: Int, points: [CGPoint], in context: CGContext) {
    guard columns >= 2, rows >= 2, points.count == columns * rows else { return }
    func source(_ column: Int, _ row: Int) -> CGPoint {
      CGPoint(x: size.width * CGFloat(column) / CGFloat(columns - 1), y: size.height * CGFloat(row) / CGFloat(rows - 1))
    }
    func point(_ column: Int, _ row: Int) -> CGPoint { points[row * columns + column] }
    // Neighbouring triangles overlap by a little over half a pixel's diagonal, so the pixels on
    // their shared edge are covered in full: their antialiased edges alone leave a faint seam.
    let ctm = context.ctm
    let pixelsPerPoint = max(sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c)), 0.001)
    let overlap = 0.75 / pixelsPerPoint
    for row in 0..<(rows - 1) {
      for column in 0..<(columns - 1) {
        let corners = [(column, row), (column + 1, row), (column + 1, row + 1), (column, row + 1)]
        for triangle in [[0, 1, 2], [0, 2, 3]] {
          let from = triangle.map { source(corners[$0].0, corners[$0].1) }
          let to = triangle.map { point(corners[$0].0, corners[$0].1) }
          guard let transform = affine(from: from, to: to) else { continue }
          context.saveGState()
          context.addPath(path(around: to, by: overlap))
          context.clip()
          context.concatenate(transform)
          context.draw(image, in: CGRect(origin: .zero, size: size))
          context.restoreGState()
        }
      }
    }
  }

  /// The transform taking the triangle `from` onto `to`; nil when either has no area.
  static func affine(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform? {
    let (s1, s2) = (from[1] - from[0], from[2] - from[0])
    let (d1, d2) = (to[1] - to[0], to[2] - to[0])
    let determinant = s1.x * s2.y - s2.x * s1.y
    guard abs(determinant) > 1e-6, abs(d1.x * d2.y - d2.x * d1.y) > 1e-6 else { return nil }
    // A = D · S⁻¹, with S and D the triangles' edges as columns.
    let a = (d1.x * s2.y - d2.x * s1.y) / determinant
    let c = (d2.x * s1.x - d1.x * s2.x) / determinant
    let b = (d1.y * s2.y - d2.y * s1.y) / determinant
    let d = (d2.y * s1.x - d1.y * s2.x) / determinant
    let tx = to[0].x - (a * from[0].x + c * from[0].y)
    let ty = to[0].y - (b * from[0].x + d * from[0].y)
    return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
  }

  /// The triangle, grown by `by` at each corner.
  private static func path(around triangle: [CGPoint], by grow: CGFloat) -> CGPath {
    let centre = CGPoint(x: triangle.map(\.x).reduce(0, +) / 3, y: triangle.map(\.y).reduce(0, +) / 3)
    let path = CGMutablePath()
    path.addLines(between: triangle.map { corner in
      let out = corner - centre
      let length = max(hypot(out.x, out.y), 0.001)
      return CGPoint(x: corner.x + out.x / length * grow, y: corner.y + out.y / length * grow)
    })
    path.closeSubpath()
    return path
  }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
