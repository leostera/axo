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
    // Wider than tall, its gills reaching out past the head.
    XCTAssertGreaterThan(width, 2 * SquishyMesh.head.x + 20)
    XCTAssertGreaterThan(width, height * 1.4)
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

  func testItsPartsAreHeadGillsAndArms() {
    let parts = SquishyMesh.axo(subdivisions: 3).parts
    XCTAssertEqual(parts.count, 642)
    let gills = parts.filter { $0.kind == .gill }
    // A good part of it is gills, out to their points.
    XCTAssertGreaterThan(gills.count, parts.count / 40)
    XCTAssertGreaterThan(parts.filter { $0.kind == .arm }.count, parts.count / 100)
    XCTAssertGreaterThan(gills.map(\.along).max()!, 0.9)
    XCTAssertTrue(gills.allSatisfy { $0.gill > 0.4 })
  }
}
