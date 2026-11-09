import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Screenshots compared against the reviewed baselines in apple/AxoPhone/Snapshots/Phone, which
/// the test bundle carries. Every screenshot is also written to the test's undeclared outputs
/// (bazel-testlogs/…/test.outputs/snapshots), where `bazel run //apple/AxoPhone:record_snapshots`
/// takes them from to become the new baselines.
///
/// The comparison ignores per-channel differences up to 18 and content a pixel higher or lower, and
/// allows at most 0.3% changed pixels, for rendering noise; it still fails on a change of size,
/// geometry or colour.
enum Snapshots {
  static let allowedChangedFraction = 0.003
  static let channelTolerance = 18

  @MainActor
  static func check(_ app: XCUIApplication, named name: String, in test: XCTestCase) {
    let png = settled(app)
    let current = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    current.name = "\(name).png"
    current.lifetime = .keepAlways
    test.add(current)
    save(png, named: name)

    let bundle = Bundle(for: SnapshotsBundleMarker.self)
    guard let baselineURL = bundle.url(forResource: name, withExtension: "png"),
      let baseline = try? Data(contentsOf: baselineURL)
    else {
      XCTFail("No baseline \(name).png: review the screenshot, then bazel run //apple/AxoPhone:record_snapshots")
      return
    }
    do {
      let changed = try changedFraction(baseline: baseline, current: png)
      let percent = String(format: "%.3f%%", changed * 100)
      print("SNAPSHOT \(name): \(percent) of pixels changed (tolerance \(allowedChangedFraction * 100)%)")
      if changed > allowedChangedFraction {
        let reference = XCTAttachment(data: baseline, uniformTypeIdentifier: "public.png")
        reference.name = "\(name)-baseline.png"
        reference.lifetime = .keepAlways
        test.add(reference)
        XCTFail("\(name) differs from its baseline in \(percent) of pixels: review the screenshot, then bazel run //apple/AxoPhone:record_snapshots")
      }
    } catch {
      XCTFail("\(name): \(error)")
    }
  }

  /// A screenshot once the screen has stopped moving: two in a row that agree, but for the text
  /// cursor blinking. A keyboard coming up, or the conversation settling at its end, takes a
  /// moment, and one taken during it lands a fraction of a point either way.
  @MainActor
  static func settled(_ app: XCUIApplication) -> Data {
    var last = app.screenshot().pngRepresentation
    for _ in 0..<12 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      let now = app.screenshot().pngRepresentation
      if let changed = try? changedFraction(baseline: last, current: now), changed < 0.0005 { return now }
      last = now
    }
    return last
  }

  /// Into TEST_UNDECLARED_OUTPUTS_DIR/snapshots: the runner is a Mac process, so it can.
  static func save(_ png: Data, named name: String) {
    guard let outputs = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] else { return }
    let directory = URL(fileURLWithPath: outputs).appendingPathComponent("snapshots")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? png.write(to: directory.appendingPathComponent("\(name).png"))
  }

  static func changedFraction(baseline: Data, current: Data) throws -> Double {
    let reference = try Pixels(png: baseline, name: "baseline")
    let now = try Pixels(png: current, name: "screenshot")
    guard reference.width == now.width, reference.height == now.height else {
      throw SnapshotError("the size changed: baseline \(reference.width)x\(reference.height), now \(now.width)x\(now.height)")
    }
    // A pixel is changed when it matches neither the baseline's pixel in its place nor the ones just
    // above and below it: content resting a pixel higher or lower, as a scroll view or the
    // keyboard settles, is noise; anything that moves further, or changes, is not.
    let row = reference.width * 4
    func differs(_ offset: Int, from other: Int) -> Bool {
      (0..<3).contains { channel in abs(Int(reference.rgba[other + channel]) - Int(now.rgba[offset + channel])) > channelTolerance }
    }
    var changed = 0
    for offset in stride(from: 0, to: reference.rgba.count, by: 4) where differs(offset, from: offset) {
      let above = offset - row >= 0 && !differs(offset, from: offset - row)
      let below = offset + row < reference.rgba.count && !differs(offset, from: offset + row)
      if !above && !below { changed += 1 }
    }
    return Double(changed) / Double(reference.width * reference.height)
  }

  struct SnapshotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// A PNG drawn into 8-bit RGBA.
  private struct Pixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(png: Data, name: String) throws {
      guard let source = CGImageSourceCreateWithData(png as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw SnapshotError("cannot read the \(name)") }
      let width = image.width
      let height = image.height
      var bytes = [UInt8](repeating: 0, count: width * height * 4)
      let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard drawn else { throw SnapshotError("cannot decode the \(name)") }
      self.width = width
      self.height = height
      rgba = bytes
    }
  }
}

/// Finds the test bundle, which carries the baselines.
private final class SnapshotsBundleMarker {}
