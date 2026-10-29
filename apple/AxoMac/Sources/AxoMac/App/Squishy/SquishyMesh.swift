import simd

/// The squishy Axo's body as a closed triangle mesh, made here rather than in a 3D editor: an
/// icosphere pushed out onto Axo's shape, which is its head (an ellipsoid, wider than tall and
/// flatter underneath) with three gill fronds a side fanning out of it as in the logo, and two
/// little arms in front. Points, x right, y up, z towards the viewer; centred on the origin.
///
/// The pieces are joined smoothly (a smooth union of their distance fields), so the gills grow out
/// of the head without a crease, and each icosphere vertex goes where a ray out from the centre
/// last leaves the joined shape.
///
/// It has no face: the face is drawn on it by the renderer, from each point's place at rest.
struct SquishyMesh {
  /// Which part of Axo a vertex is on, for its colour: its kind, how much it is gill (from 0 to
  /// 1, smoothly across where a gill grows out of the head), and on a gill how far along it (0 at
  /// the centre, 1 at the tip) and how far off its middle line (in points).
  struct Part: Equatable {
    enum Kind: Int { case head = 0, gill = 1, arm = 2 }
    var kind: Kind
    var gill: Float = 0
    var along: Float = 0
    var across: Float = 0
  }

  /// Every vertex, at rest.
  var vertices: [SIMD3<Float>]
  /// Three vertex indices each, counterclockwise seen from outside.
  var triangles: [SIMD3<UInt32>]
  /// Each vertex's part, for `axo`; all head otherwise.
  var parts: [Part] = []

  /// Half its head's width, height and depth.
  static let head = SIMD3<Float>(38, 27, 30)

  /// A gill frond or an arm: a tube along a curved spine from the centre out to `tip`, flattened
  /// front to back by `depth`. A frond is shaped like a leaf: `radius` thick inside the head, widest
  /// (`leaf`) just past where it leaves it (`root`, of its length), and tapering to a point; it curls
  /// its tip by `curl` (of its length), waves along the way by `wave`, and its edges ripple by
  /// `ripple` (of its width).
  private struct Lobe {
    var kind: Part.Kind
    var spine: [SIMD3<Float>]
    var radii: [Float]
    var depth: Float

    init(
      kind: Part.Kind, tip: SIMD3<Float>, radius: Float, leaf: Float? = nil, root: Float = 0.5,
      curl: Float = 0, wave: Float = 0, ripple: Float = 0, depth: Float = 0.7
    ) {
      self.kind = kind
      self.depth = depth
      let length = simd_length(tip)
      let axis = tip / length
      let up = Lobe.up(axis)
      let samples = 32
      spine = (0...samples).map { index in
        let t = Float(index) / Float(samples)
        // Curled up more towards its tip, and a wave and a half along it, still at both ends.
        let bend = curl * length * t * t + wave * sin(t * 3 * .pi) * t * (1 - t) * 4
        return tip * t + up * bend
      }
      radii = (0...samples).map { index in
        let t = Float(index) / Float(samples)
        guard let leaf, t > root else { return radius }
        let u = (t - root) / (1 - root)
        let ripples = 1 + ripple * sin(u * 5 * .pi)
        return max(0.7, leaf * pow(sin(.pi * (0.3 + 0.7 * u)), 0.75) * ripples)
      }
    }

    /// Up across a frond pointing along `axis`, in the picture's plane: up for one going sideways.
    static func up(_ axis: SIMD3<Float>) -> SIMD3<Float> {
      simd_normalize(SIMD3(-axis.y, axis.x, 0)) * (axis.x < 0 ? -1 : 1)
    }

    private func flattened(_ point: SIMD3<Float>) -> SIMD3<Float> { SIMD3(point.x, point.y, point.z / depth) }

    /// The nearest point of its spine to `point`: which segment, how far along it, and how far
    /// out of the tube there `point` is.
    private func nearest(_ point: SIMD3<Float>) -> (segment: Int, t: Float, distance: Float) {
      let p = flattened(point)
      var best = (segment: 0, t: Float(0), distance: Float.greatestFiniteMagnitude)
      for index in 0..<(spine.count - 1) {
        let a = flattened(spine[index]), b = flattened(spine[index + 1])
        let ab = b - a
        let t = min(1, max(0, simd_dot(p - a, ab) / simd_dot(ab, ab)))
        let radius = radii[index] + (radii[index + 1] - radii[index]) * t
        let d = simd_length(p - (a + ab * t)) - radius
        if d < best.distance { best = (index, t, d) }
      }
      return best
    }

    /// Its signed distance at `point`, roughly.
    func distance(_ point: SIMD3<Float>) -> Float { nearest(point).distance }

    /// Where `point`, on its surface, is along it and to which side.
    func part(at point: SIMD3<Float>) -> Part {
      let near = nearest(point)
      let a = spine[near.segment], b = spine[near.segment + 1]
      let up = Lobe.up(simd_normalize(b - a))
      let along = (Float(near.segment) + near.t) / Float(spine.count - 1)
      return Part(kind: kind, along: along, across: simd_dot(point - (a + (b - a) * near.t), up))
    }
  }

  private static let lobes: [Lobe] = {
    var lobes: [Lobe] = []
    // Three fronds a side, out of the back of its head, fanning from up and out to out and a
    // little down, each reaching past the head, tapering to a point with its tip curled up.
    // Out of the back of its head, fanning down its sides as in the logo, each curling up a
    // little to its point.
    for (degrees, reach, curl): (Float, Float, Float) in [(52, 54, 0.1), (22, 57, 0.12), (-8, 52, 0.14)] {
      let angle = degrees * .pi / 180
      for side: Float in [1, -1] {
        let tip = SIMD3(side * cos(angle) * reach, sin(angle) * reach * 0.88, -10)
        // It leaves the head about where the head is, that way.
        let root = 1 / simd_length(tip / head) / 1.05
        lobes.append(
          Lobe(kind: .gill, tip: tip, radius: 4.5, leaf: 5.6, root: min(0.8, root), curl: curl, wave: 1.5,
            ripple: 0.06))
      }
    }
    // Stubby arms, low in front.
    for side: Float in [1, -1] {
      lobes.append(Lobe(kind: .arm, tip: SIMD3(side * 18, -25, 13), radius: 5.5, depth: 1))
    }
    return lobes
  }()

  /// Axo, from an icosphere subdivided `subdivisions` times (4 is 2562 vertices).
  static func axo(subdivisions: Int = 4) -> SquishyMesh {
    var sphere = icosphere(subdivisions: subdivisions)
    let surfaces = sphere.vertices.map(surface)
    sphere.vertices = surfaces.map(\.point)
    sphere.parts = surfaces.map(\.part)
    return sphere
  }

  /// How far the pieces' joins are rounded, in points.
  private static let fillet: Float = 5

  /// The head's distance at `point`, roughly (an ellipsoid's, flatter underneath).
  private static func headDistance(_ point: SIMD3<Float>) -> Float {
    let radii = SIMD3(head.x, point.y < 0 ? head.y * 0.8 : head.y, head.z)
    let k0 = simd_length(point / radii), k1 = simd_length(point / (radii * radii))
    return k0 * (k0 - 1) / k1
  }

  /// The whole shape's distance at `point`: each piece smoothly joined to the head (and not to
  /// each other, so the gills stay apart).
  private static func distance(_ point: SIMD3<Float>) -> Float {
    let head = headDistance(point)
    return lobes.reduce(head) { joined, lobe in
      let d = lobe.distance(point)
      let h = max(fillet - abs(head - d), 0) / fillet
      return min(joined, min(head, d) - h * h * fillet / 4)
    }
  }

  /// Where a ray from the centre towards `direction` last leaves the shape, and which part of it
  /// is there (the piece nearest).
  private static func surface(_ direction: SIMD3<Float>) -> (point: SIMD3<Float>, part: Part) {
    // In from well outside, to the first point inside; then halved down to the surface.
    // Stepping by most of the distance to the shape, which it cannot be nearer than (roughly).
    var inside: Float = 90, outside: Float = 90
    while inside > 0 {
      let d = distance(direction * inside)
      if d <= 0 { break }
      outside = inside
      inside -= max(0.25, d * 0.6)
    }
    inside = max(inside, 0)
    for _ in 0..<24 {
      let middle = (inside + outside) / 2
      if distance(direction * middle) < 0 { inside = middle } else { outside = middle }
    }
    let point = direction * inside
    let nearest = lobes.min { $0.distance(point) < $1.distance(point) }!
    var part = nearest.distance(point) < headDistance(point) ? nearest.part(at: point) : Part(kind: .head)
    // Gill where a gill is nearer than the head, blending over a couple of points: a smooth field,
    // so the colour's edge does not follow the triangles.
    let gills = lobes.filter { $0.kind == .gill }
    let gill = gills.min { $0.distance(point) < $1.distance(point) }!
    part.gill = min(1, max(0, 0.5 + (headDistance(point) - gill.distance(point)) / 3))
    return (point, part)
  }

  /// A unit icosphere: an icosahedron with each triangle cut into four, `subdivisions` times, and
  /// every vertex pushed out onto the sphere.
  static func icosphere(subdivisions: Int) -> SquishyMesh {
    let t = (1 + Float(5).squareRoot()) / 2
    var vertices: [SIMD3<Float>] = [
      [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
      [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
    ].map(simd_normalize)
    var triangles: [SIMD3<UInt32>] = [
      [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6],
      [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10],
      [8, 6, 7], [9, 8, 1],
    ]
    for _ in 0..<subdivisions {
      var midpoints: [UInt64: UInt32] = [:]
      func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
        let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
        if let index = midpoints[key] { return index }
        vertices.append(simd_normalize((vertices[Int(a)] + vertices[Int(b)]) / 2))
        let index = UInt32(vertices.count - 1)
        midpoints[key] = index
        return index
      }
      triangles = triangles.flatMap { triangle -> [SIMD3<UInt32>] in
        let (a, b, c) = (triangle.x, triangle.y, triangle.z)
        let (ab, bc, ca) = (midpoint(a, b), midpoint(b, c), midpoint(c, a))
        return [[a, ab, ca], [b, bc, ab], [c, ca, bc], [ab, bc, ca]]
      }
    }
    return SquishyMesh(vertices: vertices, triangles: triangles)
  }

  /// Each vertex's normal, from the triangles around it, for `positions` (the vertices as they are
  /// now).
  static func normals(of positions: [SIMD3<Float>], triangles: [SIMD3<UInt32>]) -> [SIMD3<Float>] {
    var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
    for triangle in triangles {
      let (a, b, c) = (Int(triangle.x), Int(triangle.y), Int(triangle.z))
      // Not normalised: bigger triangles count for more.
      let face = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
      normals[a] += face
      normals[b] += face
      normals[c] += face
    }
    return normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 0, 1) }
  }

  /// Its volume (cubic points); positive when the triangles face out.
  var volume: Float {
    triangles.reduce(0) { total, triangle in
      let (a, b, c) = (vertices[Int(triangle.x)], vertices[Int(triangle.y)], vertices[Int(triangle.z)])
      return total + simd_dot(a, simd_cross(b, c)) / 6
    }
  }
}

/// A fine mesh of Axo moved by a coarse one: the coarse one is simulated (cheaply), and the fine
/// one drawn, so its gills stay round at the tips.
///
/// Both are the same icosphere at different depths, and an icosphere is made by cutting each
/// triangle into four, keeping the vertices it had: so the coarse mesh's vertices are the first
/// of the fine one's, and the fine triangles cut from each coarse triangle are together, 4 per
/// level per coarse triangle. Each fine vertex follows the coarse triangle it was cut from, by its
/// place in it.
struct SquishySkin {
  let coarse: SquishyMesh
  let fine: SquishyMesh
  /// For each fine vertex, the coarse vertices it follows and how much.
  private let weights: [(indices: SIMD3<Int32>, weights: SIMD3<Float>)]

  init(coarseSubdivisions: Int = 3, fineSubdivisions: Int = 5) {
    precondition(fineSubdivisions >= coarseSubdivisions)
    coarse = .axo(subdivisions: coarseSubdivisions)
    fine = .axo(subdivisions: fineSubdivisions)
    let coarseDirections = SquishyMesh.icosphere(subdivisions: coarseSubdivisions).vertices
    let fineDirections = SquishyMesh.icosphere(subdivisions: fineSubdivisions).vertices
    let cut = 1 << (2 * (fineSubdivisions - coarseSubdivisions))
    var weights = [(indices: SIMD3<Int32>, weights: SIMD3<Float>)](
      repeating: (.zero, .zero), count: fine.vertices.count)
    for (index, triangle) in fine.triangles.enumerated() {
      let parent = coarse.triangles[index / cut]
      let (a, b, c) = (coarseDirections[Int(parent.x)], coarseDirections[Int(parent.y)], coarseDirections[Int(parent.z)])
      for vertex in [triangle.x, triangle.y, triangle.z] {
        // Where the ray to it crosses the coarse triangle, as weights of its corners.
        let d = fineDirections[Int(vertex)]
        let w = SIMD3(simd_dot(d, simd_cross(b, c)), simd_dot(d, simd_cross(c, a)), simd_dot(d, simd_cross(a, b)))
        weights[Int(vertex)] = (SIMD3(Int32(parent.x), Int32(parent.y), Int32(parent.z)), w / (w.x + w.y + w.z))
      }
    }
    self.weights = weights
  }

  /// The fine mesh's vertices, for the coarse one's at `coarsePositions`: each moved as the coarse
  /// surface around it moved.
  func fineVertices(for coarsePositions: [SIMD3<Float>]) -> [SIMD3<Float>] {
    var moved = fine.vertices
    for index in moved.indices {
      let (corners, w) = weights[index]
      for k in 0..<3 {
        let corner = Int(corners[k])
        moved[index] += w[k] * (coarsePositions[corner] - coarse.vertices[corner])
      }
    }
    return moved
  }
}
