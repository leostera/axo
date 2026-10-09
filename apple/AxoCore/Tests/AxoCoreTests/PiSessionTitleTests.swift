import XCTest
@testable import AxoCore

final class PiSessionTitleTests: XCTestCase {
    func testBoundedMetadataReadSkipsLargeHistoryAndUncommittedRecords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let header = "{\"type\":\"session\",\"id\":\"conversation\"}\n"
        let huge = "{\"type\":\"message\",\"content\":\"" + String(repeating: "x", count: 200_000) + "\"}\n"
        let title = "{\"type\":\"session_info\",\"name\":\"Sidebar polish\"}\n"
        try Data((header + huge + title + "{\"type\":\"session_info\",\"name\":\"Not committed\"}").utf8).write(to: file)
        XCTAssertEqual(PiSessionTitle.read(from: file.path)?.name, "Sidebar polish")
        XCTAssertEqual(PiSessionTitle.read(from: file.path)?.conversationID, "conversation")
        let link = file.appendingPathExtension("link")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(PiSessionTitle.read(from: link.path))
    }
    func testInvalidHeaderOrNameDoesNotBecomeAWorkspaceTitle() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for data in ["garbage\n", "{\"type\":\"message\",\"id\":\"conversation\"}\n{\"type\":\"session_info\",\"name\":\"Wrong header\"}\n",
                     "{\"type\":\"session\",\"id\":\"conversation\"}\n{\"type\":\"session_info\",\"name\":\"bad\\nname\"}\n"] {
            try Data(data.utf8).write(to: file)
            XCTAssertNil(PiSessionTitle.read(from: file.path))
        }
        XCTAssertNil(PiSessionTitle.read(from: FileManager.default.temporaryDirectory.path))
    }
}
