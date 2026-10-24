import AppKit
import SwiftUI

struct TerminalSplitView<First: View, Second: View>: View {
  let direction: TerminalSplitDirection
  let ratio: Double
  let onRatioChange: (Double) -> Void
  let first: First
  let second: Second

  private let dividerThickness = TerminalPaneGeometry.dividerThickness
  private let dividerHitArea: CGFloat = 6
  private let minimumPaneSize: CGFloat = 10
  private let coordinateSpaceName: String

  init(
    id: UUID,
    direction: TerminalSplitDirection,
    ratio: Double,
    onRatioChange: @escaping (Double) -> Void,
    @ViewBuilder first: () -> First,
    @ViewBuilder second: () -> Second
  ) {
    self.direction = direction
    self.ratio = ratio
    self.onRatioChange = onRatioChange
    self.first = first()
    self.second = second()
    coordinateSpaceName = "terminal-split-\(id.uuidString)"
  }

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let (firstLength, secondLength) = TerminalPaneGeometry.splitLengths(
        axisLength: axisLength(in: size), ratio: ratio)
      let dividerPosition = firstLength + dividerThickness / 2

      ZStack(alignment: .topLeading) {
        first
          .frame(
            width: direction == .right ? firstLength : size.width,
            height: direction == .down ? firstLength : size.height
          )
          .clipped()

        second
          .frame(
            width: direction == .right ? secondLength : size.width,
            height: direction == .down ? secondLength : size.height
          )
          .clipped()
          .offset(
            x: direction == .right ? firstLength + dividerThickness : 0,
            y: direction == .down ? firstLength + dividerThickness : 0
          )

        divider
          .frame(
            width: direction == .right ? dividerHitArea : size.width,
            height: direction == .down ? dividerHitArea : size.height
          )
          .position(
            x: direction == .right ? dividerPosition : size.width / 2,
            y: direction == .down ? dividerPosition : size.height / 2
          )
          .gesture(resizeGesture(in: size))
          .onTapGesture(count: 2) {
            onRatioChange(0.5)
          }
      }
      .frame(width: size.width, height: size.height, alignment: .topLeading)
      .clipped()
      .coordinateSpace(name: coordinateSpaceName)
    }
  }

  private var divider: some View {
    Rectangle()
      .fill(Color.clear)
      .overlay {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(
            width: direction == .right ? dividerThickness : nil,
            height: direction == .down ? dividerThickness : nil
          )
      }
      .contentShape(Rectangle())
  }

  private func resizeGesture(in size: CGSize) -> some Gesture {
    DragGesture(coordinateSpace: .named(coordinateSpaceName))
      .onChanged { gesture in
        let length = axisLength(in: size)
        guard length > dividerThickness else { return }
        let availableLength = length - dividerThickness
        let location = direction == .right ? gesture.location.x : gesture.location.y
        let proposedRatio = (location - dividerThickness / 2) / availableLength
        let minimumRatio = min(0.5, minimumPaneSize / availableLength)
        let boundedRatio = min(max(proposedRatio, minimumRatio), 1 - minimumRatio)
        onRatioChange(Double(boundedRatio))
      }
  }

  private func axisLength(in size: CGSize) -> CGFloat {
    direction == .right ? size.width : size.height
  }
}
