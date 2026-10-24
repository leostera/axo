import Foundation

/// Where this client draws terminals (`axo.client.viewport.set`). The latest client to report one
/// sizes every pane no client is attached to, and new panes start at that size.
public struct ClientViewport: Codable, Equatable, Sendable {
  /// A size in points.
  public struct Size: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
      self.width = width
      self.height = height
    }
  }

  /// A size in device pixels.
  public struct PixelSize: Codable, Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32

    public init(width: UInt32, height: UInt32) {
      self.width = width
      self.height = height
    }
  }

  /// Ghostty's `window-padding-x`/`-y`, in whole points.
  public struct Padding: Codable, Equatable, Sendable {
    public var top: UInt32
    public var bottom: UInt32
    public var left: UInt32
    public var right: UInt32

    public init(top: UInt32, bottom: UInt32, left: UInt32, right: UInt32) {
      self.top = top
      self.bottom = bottom
      self.left = left
      self.right = right
    }
  }

  /// The area panes split, in points.
  public var terminalArea: Size
  /// Device pixels per point.
  public var backingScale: Double
  /// One terminal cell, in device pixels.
  public var cell: PixelSize
  public var padding: Padding
  /// Points between split panes.
  public var dividerThickness: Double

  /// `nil` when the area or cell is empty, or the scale is not positive: nothing to size from.
  public init?(
    terminalArea: Size, backingScale: Double, cell: PixelSize, padding: Padding,
    dividerThickness: Double
  ) {
    guard terminalArea.width > 0, terminalArea.height > 0, backingScale > 0,
      cell.width > 0, cell.height > 0, dividerThickness >= 0
    else { return nil }
    self.terminalArea = terminalArea
    self.backingScale = backingScale
    self.cell = cell
    self.padding = padding
    self.dividerThickness = dividerThickness
  }
}
