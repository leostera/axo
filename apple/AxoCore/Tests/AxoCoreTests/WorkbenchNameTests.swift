import Foundation
import XCTest
@testable import AxoCore

final class WorkbenchNameTests: XCTestCase {
    func testParsingReturnsCanonicalNameWithoutChangingInternalText() throws {
        let parsed = try WorkbenchName(" \nAxo 研究  session\n ")
        XCTAssertEqual(parsed.value, "Axo 研究  session")
        XCTAssertEqual(try WorkbenchName(parsed.value), parsed)
    }

    func testEmptyNamesAreRejectedAtConstruction() {
        for input in ["", " \t\r\n "] {
            XCTAssertThrowsError(try WorkbenchName(input)) { error in
                XCTAssertEqual(error as? WorkbenchName.ParseError, .empty)
            }
        }
    }

    func testBoundIsUTF8BytesRatherThanCharacters() throws {
        XCTAssertEqual(try WorkbenchName(String(repeating: "a", count: 120)).value.utf8.count, 120)
        XCTAssertEqual(try WorkbenchName(String(repeating: "😀", count: 30)).value.utf8.count, 120)
        for input in [String(repeating: "a", count: 121), String(repeating: "😀", count: 31)] {
            XCTAssertThrowsError(try WorkbenchName(input)) { error in
                XCTAssertEqual(error as? WorkbenchName.ParseError, .tooLong)
            }
        }
    }

    func testInteriorControlCharactersAreRejected() {
        for input in ["A\u{0}B", "A\nB", "A\tB", "A\u{7F}B"] {
            XCTAssertThrowsError(try WorkbenchName(input)) { error in
                XCTAssertEqual(error as? WorkbenchName.ParseError, .controlCharacter)
            }
        }
    }

    func testWireDecodersRejectNoncanonicalNamesInsteadOfSilentlyTrimming() throws {
        let workspaceID = UUID().uuidString
        let workspace: [String: String] = [
            "id": workspaceID, "name": " Axo ", "kind": "project"
        ]
        let session: [String: String] = [
            "id": UUID().uuidString, "workspaceId": workspaceID,
            "name": " Axo ", "availability": "stopped"
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogWorkspace.self,
            from: JSONSerialization.data(withJSONObject: workspace)))
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogSession.self,
            from: JSONSerialization.data(withJSONObject: session)))
    }
}
