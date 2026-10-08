import Foundation
import XCTest
@testable import AxoVoice

final class DownloadProgressTests: XCTestCase {
    func testByteCountsAreBoundedAndUnknownTotalsStayUnknown() {
        XCTAssertNil(DownloadBytes(downloaded: 1, total: 0))
        XCTAssertNil(DownloadBytes(downloaded: -1, total: 10))
        XCTAssertEqual(DownloadBytes(downloaded: 11, total: 10)?.downloaded, 10)
    }

    func testAppleFileProgressReportsActualByteCounts() {
        let native = Progress(totalUnitCount: 33_000_000)
        native.kind = .file
        native.completedUnitCount = 3_000_000
        let progress = AppleSpeechProgress.snapshot(native)
        XCTAssertEqual(progress.bytes?.downloaded, 3_000_000)
        XCTAssertEqual(progress.bytes?.total, 33_000_000)
        XCTAssertEqual(progress.stage, .downloading)
    }

    func testGenericAppleWorkUnitsAreNotMislabeledAsMegabytes() {
        let native = Progress(totalUnitCount: 100)
        native.completedUnitCount = 33
        let progress = AppleSpeechProgress.snapshot(native)
        XCTAssertNil(progress.bytes)
        XCTAssertEqual(progress.fraction, 0.33, accuracy: 0.001)
        XCTAssertEqual(progress.stage, .downloading)
    }

    func testUnknownProgressIsIndeterminate() {
        let progress = AppleSpeechProgress.snapshot(Progress(totalUnitCount: -1))
        XCTAssertNil(progress.bytes)
        XCTAssertEqual(progress.stage, .checking)
    }

    func testCompletedAssetTransferSwitchesToFinishing() {
        let native = Progress(totalUnitCount: 100)
        native.completedUnitCount = 100
        let progress = AppleSpeechProgress.snapshot(native)
        XCTAssertEqual(progress.stage, .loading)
        XCTAssertEqual(progress.fraction, 1)
    }
}
