import AppKit
import SwiftUI
import XCTest

@testable import AxoMac

@MainActor
final class TerminalSplitE2ETests: XCTestCase {
  func testTransferredSurfaceIsNoLongerResizedByItsPreviousHost() {
    let originalHost = host(width: 400, height: 600)
    let destinationHost = host(width: 700, height: 600)
    let surface = NSView()

    originalHost.attachSurface(surface)
    originalHost.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.frame, originalHost.bounds)

    destinationHost.attachSurface(surface)
    XCTAssertTrue(originalHost.subviews.isEmpty)
    XCTAssertTrue(surface.superview === destinationHost)
    XCTAssertEqual(surface.frame, destinationHost.bounds)

    originalHost.setFrameSize(NSSize(width: 100, height: 100))
    originalHost.layoutSubtreeIfNeeded()

    XCTAssertTrue(surface.superview === destinationHost)
    XCTAssertEqual(surface.frame, destinationHost.bounds)
  }

  func testTransferredSurfaceTracksDestinationHostResizes() {
    let originalHost = host(width: 300, height: 200)
    let destinationHost = host(width: 500, height: 400)
    let surface = NSView()
    originalHost.attachSurface(surface)

    destinationHost.attachSurface(surface)
    destinationHost.setFrameSize(NSSize(width: 800, height: 450))
    destinationHost.layoutSubtreeIfNeeded()

    XCTAssertTrue(surface.superview === destinationHost)
    XCTAssertEqual(surface.frame, destinationHost.bounds)
  }

  func testDetachingAndReattachingPreservesTheSurfaceObject() {
    let firstHost = host(width: 640, height: 480)
    let secondHost = host(width: 320, height: 240)
    let surface = NSView()
    weak let retainedSurface = surface

    firstHost.attachSurface(surface)
    firstHost.detachSurface()

    XCTAssertNil(surface.superview)
    XCTAssertTrue(retainedSurface === surface)

    secondHost.attachSurface(surface)

    XCTAssertTrue(surface.superview === secondHost)
    XCTAssertEqual(secondHost.subviews.count, 1)
    XCTAssertTrue(retainedSurface === surface)
  }

  func testReplacingHostSurfaceRemovesOnlyThePreviousChild() {
    let host = host(width: 640, height: 480)
    let firstSurface = NSView()
    let secondSurface = NSView()
    host.attachSurface(firstSurface)

    host.attachSurface(secondSurface)

    XCTAssertNil(firstSurface.superview)
    XCTAssertTrue(secondSurface.superview === host)
    XCTAssertEqual(host.subviews.count, 1)
    XCTAssertEqual(secondSurface.frame, host.bounds)
  }

  func testAttachingTheSameSurfaceTwiceDoesNotDuplicateIt() {
    let host = host(width: 640, height: 480)
    let surface = NSView()

    host.attachSurface(surface)
    host.attachSurface(surface)

    XCTAssertTrue(surface.superview === host)
    XCTAssertEqual(host.subviews.count, 1)
  }

  func testSeveralSurfacesRemainBoundToTheirOwnHostsAfterReparenting() {
    let oldLeftHost = host(width: 400, height: 600)
    let oldRightHost = host(width: 400, height: 600)
    let newLeftHost = host(width: 600, height: 600)
    let newRightHost = host(width: 200, height: 300)
    let leftSurface = NSView()
    let rightSurface = NSView()

    oldLeftHost.attachSurface(leftSurface)
    oldRightHost.attachSurface(rightSurface)
    newLeftHost.attachSurface(leftSurface)
    newRightHost.attachSurface(rightSurface)

    oldLeftHost.setFrameSize(NSSize(width: 1_000, height: 900))
    oldRightHost.setFrameSize(NSSize(width: 1_000, height: 900))
    oldLeftHost.layoutSubtreeIfNeeded()
    oldRightHost.layoutSubtreeIfNeeded()

    XCTAssertTrue(leftSurface.superview === newLeftHost)
    XCTAssertEqual(leftSurface.frame, newLeftHost.bounds)
    XCTAssertTrue(rightSurface.superview === newRightHost)
    XCTAssertEqual(rightSurface.frame, newRightHost.bounds)
  }

  func testSwiftUISplitGeometryUsesRatioAndKeepsDividerGapForRightSplit() throws {
    let splitID = UUID()
    let coordinateSpace = "terminal-split-\(splitID.uuidString)"
    let frames = PaneFrameRecorder()
    let hostingView = hostView(
      TerminalSplitView(
        id: splitID,
        direction: .right,
        ratio: 0.3,
        onRatioChange: { _ in },
        first: { PaneFrameProbe(name: "first", space: coordinateSpace, frames: frames) },
        second: { PaneFrameProbe(name: "second", space: coordinateSpace, frames: frames) }
      ),
      width: 1_000,
      height: 600
    )

    XCTAssertEqual(hostingView.frame.size, CGSize(width: 1_000, height: 600))
    let first = try XCTUnwrap(frames.frame(for: "first"))
    let second = try XCTUnwrap(frames.frame(for: "second"))

    XCTAssertEqual(first.minX, 0, accuracy: 1)
    XCTAssertEqual(first.width, 299.7, accuracy: 1)
    XCTAssertEqual(second.minX, 300.7, accuracy: 1)
    XCTAssertEqual(second.width, 699.3, accuracy: 1)
    XCTAssertEqual(first.height, 600, accuracy: 1)
    XCTAssertEqual(second.height, 600, accuracy: 1)
  }

  func testSwiftUISplitGeometryUsesRatioForDownSplit() throws {
    let splitID = UUID()
    let coordinateSpace = "terminal-split-\(splitID.uuidString)"
    let frames = PaneFrameRecorder()
    let hostingView = hostView(
      TerminalSplitView(
        id: splitID,
        direction: .down,
        ratio: 0.25,
        onRatioChange: { _ in },
        first: { PaneFrameProbe(name: "first", space: coordinateSpace, frames: frames) },
        second: { PaneFrameProbe(name: "second", space: coordinateSpace, frames: frames) }
      ),
      width: 1_000,
      height: 600
    )

    XCTAssertEqual(hostingView.frame.size, CGSize(width: 1_000, height: 600))
    let first = try XCTUnwrap(frames.frame(for: "first"))
    let second = try XCTUnwrap(frames.frame(for: "second"))

    XCTAssertEqual(first.minY, 0, accuracy: 1)
    XCTAssertEqual(first.height, 149.75, accuracy: 1)
    XCTAssertEqual(second.minY, 150.75, accuracy: 1)
    XCTAssertEqual(second.height, 449.25, accuracy: 1)
    XCTAssertEqual(first.width, 1_000, accuracy: 1)
    XCTAssertEqual(second.width, 1_000, accuracy: 1)
  }

  func testNestedSwiftUISplitsPlaceAllSurfacesInDistinctFrames() throws {
    let outerID = UUID()
    let innerID = UUID()
    let outerSpace = "terminal-split-\(outerID.uuidString)"
    let frames = PaneFrameRecorder()
    let hostingView = hostView(
      TerminalSplitView(
        id: outerID,
        direction: .right,
        ratio: 0.5,
        onRatioChange: { _ in },
        first: { PaneFrameProbe(name: "left", space: outerSpace, frames: frames) },
        second: {
          TerminalSplitView(
            id: innerID,
            direction: .down,
            ratio: 0.5,
            onRatioChange: { _ in },
            first: { PaneFrameProbe(name: "top", space: outerSpace, frames: frames) },
            second: { PaneFrameProbe(name: "bottom", space: outerSpace, frames: frames) }
          )
        }
      ),
      width: 1_000,
      height: 600
    )

    XCTAssertEqual(hostingView.frame.size, CGSize(width: 1_000, height: 600))
    let left = try XCTUnwrap(frames.frame(for: "left"))
    let top = try XCTUnwrap(frames.frame(for: "top"))
    let bottom = try XCTUnwrap(frames.frame(for: "bottom"))

    XCTAssertEqual(left.minX, 0, accuracy: 1)
    XCTAssertEqual(left.width, 499.5, accuracy: 1)
    XCTAssertEqual(top.minX, 500.5, accuracy: 1)
    XCTAssertEqual(top.minY, 0, accuracy: 1)
    XCTAssertEqual(top.width, 499.5, accuracy: 1)
    XCTAssertEqual(top.height, 299.5, accuracy: 1)
    XCTAssertEqual(bottom.minX, 500.5, accuracy: 1)
    XCTAssertEqual(bottom.minY, 300.5, accuracy: 1)
    XCTAssertEqual(bottom.height, 299.5, accuracy: 1)
  }

  func testNestedSplitsPreserveUnrelatedBranchesAndRatios() throws {
    let original = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.6,
      first: .pane(11),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.4,
        first: .pane(17),
        second: .pane(23)
      )
    )
    let nestedSplitID = try XCTUnwrap(original.splitID(containing: 17))

    let updated = try XCTUnwrap(
      original.inserting(shellID: 29, direction: .down, beside: 17)
    )

    XCTAssertEqual(updated.shellIDs, [11, 17, 23, 29])
    XCTAssertEqual(updated.ratio(for: nestedSplitID), 0.4)
    XCTAssertEqual(updated.ratio(for: original.rootSplitID!), 0.6)
    XCTAssertTrue(updated.contains(shellID: 23))
    XCTAssertTrue(updated.contains(shellID: 29))
  }

  func testClosingOnePaneKeepsOtherSplitRatiosAndShells() throws {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.65,
      first: .pane(11),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.35,
        first: .pane(17),
        second: .pane(23)
      )
    )

    let updated = try XCTUnwrap(layout.removing(shellID: 17))

    XCTAssertEqual(updated.shellIDs, [11, 23])
    XCTAssertEqual(updated.ratio(for: layout.rootSplitID!), 0.65)
    XCTAssertEqual(
      updated,
      .split(
        id: layout.rootSplitID!,
        direction: .right,
        ratio: 0.65,
        first: .pane(11),
        second: .pane(23)
      ))
  }

  func testResizingOneSplitDoesNotChangeStructureOrSiblingRatio() throws {
    let original = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.55,
      first: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.45,
        first: .pane(11),
        second: .pane(17)
      ),
      second: .pane(23)
    )
    let nestedID = try XCTUnwrap(original.splitID(containing: 11))

    let resized = try XCTUnwrap(original.resizing(splitID: nestedID, to: 0.7))

    XCTAssertEqual(resized.structuralIdentity, original.structuralIdentity)
    XCTAssertEqual(resized.ratio(for: nestedID), 0.7)
    XCTAssertEqual(resized.ratio(for: original.rootSplitID!), 0.55)
    XCTAssertEqual(resized.shellIDs, original.shellIDs)
  }

  func testRemovingLastLeafCollapsesEveryEmptyAncestor() {
    let layout = TerminalLayout.split(
      id: UUID(),
      direction: .right,
      ratio: 0.6,
      first: .pane(11),
      second: .split(
        id: UUID(),
        direction: .down,
        ratio: 0.4,
        first: .pane(17),
        second: .pane(23)
      )
    )

    XCTAssertEqual(layout.pruned(to: [23]), .pane(23))
  }

  private func host(width: CGFloat, height: CGFloat) -> GhosttySurfaceHostNSView {
    GhosttySurfaceHostNSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
  }

  private func hostView<Content: View>(
    _ content: Content,
    width: CGFloat,
    height: CGFloat
  ) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = CGRect(x: 0, y: 0, width: width, height: height)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    hostingView.layoutSubtreeIfNeeded()
    return hostingView
  }
}

@MainActor
private final class PaneFrameRecorder {
  private var frames: [String: CGRect] = [:]

  func record(_ name: String, frame: CGRect) {
    frames[name] = frame
  }

  func frame(for name: String) -> CGRect? {
    frames[name]
  }
}

private struct PaneFrameProbe: View {
  let name: String
  let space: String
  let frames: PaneFrameRecorder

  var body: some View {
    GeometryReader { geometry in
      Color.clear
        .onAppear { frames.record(name, frame: geometry.frame(in: .named(space))) }
        .onChange(of: geometry.frame(in: .named(space))) { frame in
          frames.record(name, frame: frame)
        }
    }
  }
}

extension TerminalLayout {
  fileprivate var rootSplitID: UUID? {
    guard case .split(let id, _, _, _, _) = self else { return nil }
    return id
  }

  fileprivate func splitID(containing shellID: Int64) -> UUID? {
    guard case .split(let id, _, _, let first, let second) = self else { return nil }
    if first.contains(shellID: shellID) { return first.splitID(containing: shellID) ?? id }
    if second.contains(shellID: shellID) { return second.splitID(containing: shellID) ?? id }
    return nil
  }

  fileprivate func ratio(for splitID: UUID) -> Double? {
    guard case .split(let id, _, let ratio, let first, let second) = self else { return nil }
    if id == splitID { return ratio }
    return first.ratio(for: splitID) ?? second.ratio(for: splitID)
  }
}
