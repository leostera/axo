import AxoPhoneModel
import SwiftUI

/// Shared phone/Watch waveform. Every bar is a real measured microphone level; silence is flat.
public struct AudioWaveform: View {
  private let level: @MainActor () -> Double
  private let height: CGFloat
  @State private var levels: [Double]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(bars: Int = 30, height: CGFloat = 30, level: @escaping @MainActor () -> Double) {
    self.level = level
    self.height = height
    _levels = State(initialValue: Array(repeating: 0, count: min(64, max(4, bars))))
  }

  public var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 0.2 : 0.05)) { context in
      HStack(spacing: 3) {
        ForEach(levels.indices, id: \.self) { index in
          Capsule().fill(Color.secondary)
            .frame(height: max(3, VoiceWaveformScale.heightFraction(for: levels[index]) * height))
            .frame(maxWidth: .infinity)
        }
      }
      .frame(height: height + 4)
      .onChange(of: context.date) {
        levels.removeFirst()
        levels.append(level())
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Listening")
  }
}
