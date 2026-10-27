import CoreGraphics
import Foundation
import ImageIO

let allowedChangedFraction = 0.003
let channelTolerance = 18

struct Pixels {
  let width: Int
  let height: Int
  let rgba: [UInt8]

  init(path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw SnapshotError.cannotRead(path)
    }
    let imageWidth = image.width
    let imageHeight = image.height
    var bytes = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let alphaInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(alphaInfo)
    let decoded = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress,
        width: imageWidth,
        height: imageHeight,
        bitsPerComponent: 8,
        bytesPerRow: imageWidth * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      ) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
      return true
    }
    guard decoded else { throw SnapshotError.cannotDecode(path) }
    width = imageWidth
    height = imageHeight
    rgba = bytes
  }
}

enum SnapshotError: Error, CustomStringConvertible {
  case cannotRead(String)
  case cannotDecode(String)
  case sizeMismatch(reference: String, current: String)

  var description: String {
    switch self {
    case .cannotRead(let path): "Could not read PNG: \(path)"
    case .cannotDecode(let path): "Could not decode PNG: \(path)"
    case .sizeMismatch(let reference, let current): "Snapshot dimensions differ: reference \(reference), current \(current)"
    }
  }
}

func compare(referencePath: String, currentPath: String) throws -> Bool {
  let reference = try Pixels(path: referencePath)
  let current = try Pixels(path: currentPath)
  guard reference.width == current.width, reference.height == current.height else {
    throw SnapshotError.sizeMismatch(
      reference: "\(reference.width)x\(reference.height)",
      current: "\(current.width)x\(current.height)"
    )
  }

  var changedPixels = 0
  for offset in stride(from: 0, to: reference.rgba.count, by: 4) {
    let differs = (0..<3).contains { channel in
      abs(Int(reference.rgba[offset + channel]) - Int(current.rgba[offset + channel])) > channelTolerance
    }
    if differs { changedPixels += 1 }
  }

  let pixelCount = reference.width * reference.height
  let changedFraction = Double(changedPixels) / Double(pixelCount)
  let passed = changedFraction <= allowedChangedFraction
  let percent = String(format: "%.3f%%", changedFraction * 100)
  print("\(passed ? "PASS" : "FAIL") \((currentPath as NSString).lastPathComponent): \(percent) changed pixels (tolerance \(allowedChangedFraction * 100)%)")
  return passed
}

guard CommandLine.arguments.count == 3 else {
  fputs("usage: compare-phone-snapshots.swift <reference.png> <current.png>\n", stderr)
  exit(2)
}

do {
  if try !compare(referencePath: CommandLine.arguments[1], currentPath: CommandLine.arguments[2]) {
    exit(1)
  }
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
