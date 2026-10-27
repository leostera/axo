import XCTest

extension XCUIElement {
  /// Taps the middle of this element, where a person would.
  ///
  /// The app's layers that are not showing stay in the tree UI tests read (VoiceOver skips
  /// them), some as one element as big as the layer. `tap()` looks for a point where nothing
  /// else lies over the element, finds one of those, and taps somewhere else; a tap on the
  /// coordinates goes, as a finger would, to what is drawn on top.
  func tapWhereItIs() {
    coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
  }
}
