import XCTest
@testable import AxoVoice

final class VoiceWaveformScaleTests: XCTestCase {
    func testSilenceInvalidInputAndBelowFloorRemainQuiet() {
        for level in [0, -1, Double.nan, Double.infinity, -Double.infinity, pow(10, -65.0 / 20)] {
            XCTAssertEqual(VoiceWaveformScale.heightFraction(for: level), 0)
        }
    }

    func testQuietSpeechIsVisibleWithoutSaturating() {
        let quietAmplitude = pow(10, -50.0 / 20)
        let quietHeight = VoiceWaveformScale.heightFraction(for: quietAmplitude) * 32
        XCTAssertGreaterThan(quietHeight, 10)
        XCTAssertLessThan(quietHeight, 16)
        XCTAssertLessThan(sqrt(quietAmplitude) * 32, 3) // Previously collapsed to the baseline.
        let normalHeight = VoiceWaveformScale.heightFraction(for: pow(10, -35.0 / 20)) * 32
        XCTAssertGreaterThan(normalHeight, quietHeight)
        XCTAssertLessThan(normalHeight, 32)
    }

    func testScaleIsMonotonicBoundedAndClipsLoudInput() {
        var previous = 0.0
        for decibels in stride(from: -80.0, through: 0, by: 0.5) {
            let height = VoiceWaveformScale.heightFraction(for: pow(10, decibels / 20))
            XCTAssertGreaterThanOrEqual(height, previous)
            XCTAssertTrue((0...1).contains(height))
            previous = height
        }
        XCTAssertEqual(VoiceWaveformScale.heightFraction(for: pow(10, -18.0 / 20)), 1, accuracy: 0.000_001)
        XCTAssertEqual(VoiceWaveformScale.heightFraction(for: 2), 1)
    }
}
