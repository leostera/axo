import Foundation
import QuartzCore
import SwiftUI

/// Moves a layer sideways, as `.offset(x:)` does. When the motion of a swipe is being measured
/// (`PreviewFixture.motionLog`), it also notes where every frame puts the layer: SwiftUI hands an
/// animatable effect the in-between value of each frame of a spring, as well as each step of a drag.
struct LayerOffset: GeometryEffect {
  var x: CGFloat
  let log: LayerMotionLog?

  var animatableData: CGFloat {
    get { x }
    set { x = newValue }
  }

  func effectValue(size: CGSize) -> ProjectionTransform {
    log?.note(x)
    return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
  }
}

/// Where a layer was at each frame, appended to a file as "seconds points" lines, for
/// AxoPhoneMotionTests. It exists only in the simulator preview.
final class LayerMotionLog: @unchecked Sendable {
  private let file: FileHandle
  private let lock = NSLock()
  private var last: CGFloat?

  init?(path: String) {
    guard FileManager.default.createFile(atPath: path, contents: nil),
      let file = FileHandle(forWritingAtPath: path)
    else { return nil }
    self.file = file
  }

  /// Notes `x` now, unless the layer has not moved: a frame is noted only when it changes, as a
  /// screen recording would, so a rest shows as a gap.
  func note(_ x: CGFloat) {
    lock.lock()
    defer { lock.unlock() }
    guard x != last else { return }
    last = x
    file.write(Data(String(format: "%.6f %.3f\n", CACurrentMediaTime(), Double(x)).utf8))
  }
}
