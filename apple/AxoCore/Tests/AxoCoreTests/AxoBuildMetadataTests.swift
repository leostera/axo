import XCTest
@testable import AxoCore

final class AxoBuildMetadataTests: XCTestCase {
    func testPackagedMetadataUsesActualAppAndBundledDaemonVersions() {
        let commit = "5c794a4a0123456789abcdef0123456789abcdef"
        let metadata = AxoBuildMetadata(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "123",
            "AxoBundledAxodVersion": "0.1.0 (5c794a4a)", "AxoBuildCommit": commit])
        XCTAssertEqual(metadata.version, "0.1.0")
        XCTAssertEqual(metadata.daemonVersion, "0.1.0")
        XCTAssertEqual(metadata.build, "123")
        XCTAssertEqual(metadata.commit, commit)
        XCTAssertEqual(metadata.commitURL?.absoluteString, "https://github.com/leostera/axo/commit/\(commit)")
    }
    func testUnpackagedOrMalformedValuesAreUnavailableNotFabricated() {
        let missing = AxoBuildMetadata(info: [:])
        XCTAssertEqual(missing.version, "Unavailable")
        XCTAssertEqual(missing.daemonVersion, "Unavailable")
        XCTAssertNil(missing.commitURL)
        let malformed = AxoBuildMetadata(info: ["AxoBuildCommit": "../../private", "CFBundleVersion": "bad\nvalue"])
        XCTAssertEqual(malformed.commit, "Unavailable")
        XCTAssertEqual(malformed.build, "Unavailable")
        XCTAssertNil(malformed.commitURL)
    }
}
