import XCTest
import simd

@testable import AxoMac

final class SquishyMeshTests: XCTestCase {
  /// Coarse, as it is simulated (and quick to make in a debug build).
  private let axo = SquishyMesh.axo(subdivisions: 3)

  func testItIsAClosedSurfaceFacingOut() {
    XCTAssertEqual(axo.vertices.count, 642)
    XCTAssertEqual(axo.triangles.count, 1280)
    // Closed: every edge is shared by two triangles, once each way round.
    var edges: [SIMD2<UInt32>: Int] = [:]
    for t in axo.triangles {
      for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { edges[SIMD2(a, b), default: 0] += 1 }
    }
    XCTAssertTrue(edges.allSatisfy { $0.value == 1 && edges[SIMD2($0.key.y, $0.key.x)] == 1 })
    XCTAssertGreaterThan(axo.volume, 0)
  }

  func testItIsShapedLikeAxo() {
    let xs = axo.vertices.map(\.x), ys = axo.vertices.map(\.y), zs = axo.vertices.map(\.z)
    let width = xs.max()! - xs.min()!, height = ys.max()! - ys.min()!, depth = zs.max()! - zs.min()!
    // As in the logo: its gills reaching out past its head, to over twice as wide as tall.
    XCTAssertGreaterThan(width, 2 * SquishyMesh.head.x + 30)
    XCTAssertEqual(width / height, 2.3, accuracy: 0.3)
    XCTAssertLessThan(depth, width / 1.5)
    // Symmetric, and flatter underneath than on top.
    XCTAssertEqual(xs.max()!, -xs.min()!, accuracy: 0.5)
    XCTAssertLessThan(-ys.min()!, ys.max()!)
  }

  func testNormalsPointOutOfASphere() {
    let sphere = SquishyMesh.icosphere(subdivisions: 2)
    let normals = SquishyMesh.normals(of: sphere.vertices, triangles: sphere.triangles)
    for (vertex, normal) in zip(sphere.vertices, normals) {
      XCTAssertGreaterThan(simd_dot(vertex, normal), 0.99)
    }
  }
}

final class SquishySkinTests: XCTestCase {
  func testTheFineMeshFollowsTheCoarseOne() {
    let skin = SquishySkin(coarseSubdivisions: 2, fineSubdivisions: 3)
    // At rest it is itself.
    XCTAssertEqual(skin.fineVertices(for: skin.coarse.vertices), skin.fine.vertices)
    // Moved, it moves alike.
    let shift = SIMD3<Float>(5, -3, 2)
    for (moved, rest) in zip(skin.fineVertices(for: skin.coarse.vertices.map { $0 + shift }), skin.fine.vertices) {
      XCTAssertLessThan(simd_length(moved - rest - shift), 1e-3)
    }
    // Its shared vertices follow their own coarse vertex.
    var dented = skin.coarse.vertices
    dented[0] += shift
    XCTAssertLessThan(simd_length(skin.fineVertices(for: dented)[0] - skin.fine.vertices[0] - shift), 1e-3)
  }

  func testItsPartsAreItsHeadAndItsGills() {
    let parts = SquishyMesh.axo(subdivisions: 3).parts
    XCTAssertEqual(parts.count, 642)
    // A good part of it is gills, and most of it head.
    let gills = parts.filter { $0.gill > 0.5 }.count
    XCTAssertGreaterThan(gills, parts.count / 25)
    XCTAssertLessThan(gills, parts.count / 2)
  }

}
