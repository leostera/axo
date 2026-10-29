import simd

/// The squishy Axo's body as a closed triangle mesh, made here rather than in a 3D editor, after
/// the logo: a wide dome of a head, flatter underneath, with three short, round gill lobes a side
/// stacked on its sides (up and out, out, and a little down). Points, x right, y up, z towards
/// the viewer; centred on the origin.
///
/// An icosphere, each vertex pushed out to where a ray from the centre last leaves the shape:
/// the head and each lobe as distance fields, each lobe smoothly joined to the head (and not to
/// the others, so they stay apart).
///
/// It has no face: the face is drawn on it by the renderer, from each point's place at rest.
struct SquishyMesh {
  /// Which part of Axo a vertex is on: how much it is gill, from 0 to 1, smoothly across where a
  /// gill grows out of the head (the face is drawn only on the head).
  struct Part: Equatable {
    var gill: Float = 0
  }

  /// Every vertex, at rest.
  var vertices: [SIMD3<Float>]
  /// Three vertex indices each, counterclockwise seen from outside.
  var triangles: [SIMD3<UInt32>]
  /// Each vertex's part, for `axo`; all head otherwise.
  var parts: [Part] = []

  /// Half its head's width, height (above; it is flatter underneath) and depth: the logo's
  /// proportions, about 1.4 times as wide as tall.
  static let head = SIMD3<Float>(40, 28, 28)
  private static let underneath: Float = 0.85

  /// A gill lobe: a capsule from inside the head out to `tip`, `radius` thick, flattened front to
  /// back by `depth`, a little behind the face.
  private struct Lobe {
    var root: SIMD3<Float>
    var tip: SIMD3<Float>
    var radius: Float
    var depth: Float = 0.75

    func distance(_ point: SIMD3<Float>) -> Float {
      let flat = SIMD3<Float>(1, 1, 1 / depth)
      let p = point * flat, a = root * flat, b = tip * flat
      let t = min(1, max(0, simd_dot(p - a, b - a) / simd_length_squared(b - a)))
      return simd_length(p - (a + (b - a) * t)) - radius
    }
  }

  /// After the logo, in head half-widths from its middle: the middle of each lobe's round end,
  /// top, middle and bottom, a side; each starts inside the head, towards the middle.
  private static let lobes: [Lobe] = {
    let tips: [SIMD2<Float>] = [[1.2, 0.62], [1.42, 0.22], [1.34, -0.17]]
    return tips.flatMap { tip in
      [Float(1), -1].map { side in
        Lobe(
          root: SIMD3(side * 0.55 * head.x, tip.y * 0.6 * head.x, -6),
          tip: SIMD3(side * tip.x * head.x, tip.y * head.x, -6), radius: 0.19 * head.x)
      }
    }
  }()

  /// How far each lobe's join to the head is rounded, in points.
  private static let fillet: Float = 4

  /// Axo, from an icosphere subdivided `subdivisions` times (4 is 2562 vertices).
  static func axo(subdivisions: Int = 4) -> SquishyMesh {
    var sphere = icosphere(subdivisions: subdivisions)
    let surfaces = sphere.vertices.map(surface)
    sphere.vertices = surfaces.map(\.point)
    sphere.parts = surfaces.map(\.part)
    return sphere
  }

  /// The head's distance at `point`, roughly (an ellipsoid's, flatter underneath).
  private static func headDistance(_ point: SIMD3<Float>) -> Float {
    let radii = SIMD3(head.x, point.y < 0 ? head.y * underneath : head.y, head.z)
    let k0 = simd_length(point / radii), k1 = simd_length(point / (radii * radii))
    return k0 * (k0 - 1) / k1
  }

  /// The whole shape's distance at `point`.
  private static func distance(_ point: SIMD3<Float>) -> Float {
    let head = headDistance(point)
    return lobes.reduce(head) { joined, lobe in
      let d = lobe.distance(point)
      let h = max(fillet - abs(head - d), 0) / fillet
      return min(joined, min(head, d) - h * h * fillet / 4)
    }
  }

  /// Where a ray from the centre towards `direction` last leaves the shape, and which part of it
  /// is there.
  private static func surface(_ direction: SIMD3<Float>) -> (point: SIMD3<Float>, part: Part) {
    // In from well outside, stepping by most of the distance to the shape (which it cannot be
    // nearer than, roughly), to the first point inside; then halved down to the surface.
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
    let lobe = lobes.map { $0.distance(point) }.min()!
    // Gill where a gill is nearer than the head, blending over a couple of points: a smooth field,
    // so its edge does not follow the triangles.
    return (point, Part(gill: min(1, max(0, 0.5 + (headDistance(point) - lobe) / 3))))
  }

  /// The head's and the lobes' distance fields in Metal, the same as here, for the renderer to
  /// ink where they meet on the surface: `head_distance(p)` and `lobe_distance(i, p)` for `i` below
  /// `LOBES`.
  static var shaderShape: String {
    func f(_ v: Float) -> String { String(format: "%.4f", v) }
    func f3(_ v: SIMD3<Float>) -> String { "float3(\(f(v.x)), \(f(v.y)), \(f(v.z)))" }
    return """
      constant int LOBES = \(lobes.count);
      constant float3 lobe_roots[] = { \(lobes.map { f3($0.root) }.joined(separator: ", ")) };
      constant float3 lobe_tips[] = { \(lobes.map { f3($0.tip) }.joined(separator: ", ")) };
      constant float lobe_radii[] = { \(lobes.map { f($0.radius) }.joined(separator: ", ")) };
      constant float lobe_depths[] = { \(lobes.map { f($0.depth) }.joined(separator: ", ")) };

      static float head_distance(float3 p) {
        float3 radii = float3(\(f(head.x)), p.y < 0 ? \(f(head.y * underneath)) : \(f(head.y)), \(f(head.z)));
        float k0 = length(p / radii), k1 = length(p / (radii * radii));
        return k0 * (k0 - 1) / k1;
      }

      static float lobe_distance(int i, float3 p) {
        float3 flat = float3(1, 1, 1 / lobe_depths[i]);
        float3 q = p * flat, a = lobe_roots[i] * flat, b = lobe_tips[i] * flat;
        float t = clamp(dot(q - a, b - a) / dot(b - a, b - a), 0.0, 1.0);
        return length(q - (a + (b - a) * t)) - lobe_radii[i];
      }
      """
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
