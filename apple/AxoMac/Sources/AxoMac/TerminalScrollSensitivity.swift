import Foundation

/// Maps the scroll-sensitivity preference onto a slider with its neutral value centered.
enum TerminalScrollSensitivity {
  static let preferenceKey = AxoPreferenceKey.scrollSensitivity
  static let minimumMultiplier = 0.1
  static let defaultMultiplier = 1.0
  static let maximumMultiplier = 3.0
  static let neutralSliderPosition = 0.5

  /// Converts an input multiplier to the slider's normalized 0...1 position.
  static func sliderPosition(for multiplier: Double) -> Double {
    let multiplier = boundedMultiplier(multiplier)
    if multiplier <= defaultMultiplier {
      let lowerRange = defaultMultiplier - minimumMultiplier
      return neutralSliderPosition * (multiplier - minimumMultiplier) / lowerRange
    }

    let upperRange = maximumMultiplier - defaultMultiplier
    return neutralSliderPosition
      + neutralSliderPosition * (multiplier - defaultMultiplier) / upperRange
  }

  /// Converts a normalized slider position into a scroll-sensitivity multiplier.
  static func multiplier(atSliderPosition position: Double) -> Double {
    guard position.isFinite else { return defaultMultiplier }
    let position = min(max(position, 0), 1)
    if position <= neutralSliderPosition {
      let lowerRange = defaultMultiplier - minimumMultiplier
      return minimumMultiplier + position / neutralSliderPosition * lowerRange
    }

    let upperRange = maximumMultiplier - defaultMultiplier
    return defaultMultiplier
      + (position - neutralSliderPosition) / neutralSliderPosition * upperRange
  }

  /// Keeps persisted preferences inside the supported range.
  static func boundedMultiplier(_ multiplier: Double) -> Double {
    guard multiplier.isFinite else { return defaultMultiplier }
    return min(max(multiplier, minimumMultiplier), maximumMultiplier)
  }
}
