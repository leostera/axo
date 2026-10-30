import AxoMascotRive
import CoreGraphics
import Foundation
import ImageIO
import RiveRuntime
import UniformTypeIdentifiers
import XCTest

/// Plays the generated `axo.riv` in the real Rive runtime, the way the menu bar and Dock do.
/// Frames are written to the test's undeclared outputs for a look.
@MainActor
final class AxoMascotRiveTests: XCTestCase {
  /// The names AxoMascot uses (`MascotContract` in packages/axo-mascot).
  private let markArtboard = "Mark"
  private let iconArtboard = "Icon"

  private func animation() throws -> RiveMascotAnimation {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "axo", withExtension: "riv"), "bundled by Bazel")
    return RiveMascotAnimation(source: { try Data(contentsOf: url) })
  }

  func testFileHasTheArtboardsAndStateMachineTheAppUses() async throws {
    let (file, _) = try await animation().load()
    let artboards = try await file.getArtboardNames()
    XCTAssertTrue(artboards.contains(markArtboard), "\(artboards)")
    XCTAssertTrue(artboards.contains(iconArtboard), "\(artboards)")
    for name in [markArtboard, iconArtboard] {
      let machines = try await file.createArtboard(name).getStateMachineNames()
      XCTAssertEqual(machines, [RiveMascotAnimation.stateMachine], name)
    }
  }

  func testMarkDrawsAndBlinksWithinTheFirstWait() async throws {
    let player = try await animation().makeFrameSource(artboard: markArtboard, pixelSize: CGSize(width: 60, height: 32))

    let first = try await XCTUnwrapAsync(try await player.nextFrame(advancingBy: 0))
    XCTAssertGreaterThan(Self.opaquePixels(first), 100, "the open-eyed axolotl draws something")
    try Self.save(first, as: "mark-open")

    // The state machine waits 2 s, then blinks for about 0.23 s.
    var changes: [CGImage] = []
    for _ in 0..<(60 * 3) {
      if let frame = try await player.nextFrame(advancingBy: 1.0 / 60) { changes.append(frame) }
    }
    XCTAssertFalse(changes.isEmpty, "the eyes move within three seconds")
    let mostClosed = try XCTUnwrap(changes.min { Self.opaquePixels($0) < Self.opaquePixels($1) })
    XCTAssertLessThan(Self.opaquePixels(mostClosed), Self.opaquePixels(first), "closed eyes cover less")
    try Self.save(mostClosed, as: "mark-closed")
  }

  func testIconDrawsAnOpaqueRoundedSquare() async throws {
    let player = try await animation().makeFrameSource(artboard: iconArtboard, pixelSize: CGSize(width: 256, height: 256))
    let frame = try await XCTUnwrapAsync(try await player.nextFrame(advancingBy: 0))
    try Self.save(frame, as: "icon")
    let opaque = Double(Self.opaquePixels(frame)) / Double(256 * 256)
    // The rounded square fills 80% of each side, less its corners.
    XCTAssertEqual(opaque, 0.62, accuracy: 0.05)
  }

  private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped)
  }

  private static func opaquePixels(_ image: CGImage) -> Int {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return 0 }
    return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 128 }.count
  }

  private static func save(_ image: CGImage, as name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] else { return }
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
