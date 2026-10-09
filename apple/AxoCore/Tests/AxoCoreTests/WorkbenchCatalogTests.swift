import Foundation
import XCTest
@testable import AxoCore

final class WorkbenchCatalogTests: XCTestCase {
    func testPagesBuildOneCatalogAndRevisionChangesReplaceIt() throws {
        var catalog = WorkbenchCatalog()
        let workspaceID = "11111111-1111-4111-8111-111111111111"
        let sessionID = "22222222-2222-4222-8222-222222222222"

        XCTAssertTrue(try catalog.apply(page(#"{"type":"catalog_page","revision":4,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}}],"nextCursor":"4:1","hostOnline":true}"#)))
        XCTAssertEqual(catalog.workspaces.count, 1)
        XCTAssertTrue(catalog.sessions.isEmpty)
        XCTAssertEqual(catalog.nextCursor, "4:1")

        XCTAssertFalse(try catalog.apply(page(#"{"type":"catalog_page","requestId":"next","revision":4,"items":[{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"iOS","conversationId":"pi-1","availability":"running"}}],"nextCursor":null,"hostOnline":true}"#)))
        XCTAssertEqual(catalog.sessions.first?.id.rawValue.uuidString.lowercased(), sessionID)
        XCTAssertEqual(catalog.sessions(in: WorkspaceID(UUID(uuidString: workspaceID)!)).count, 1)

        XCTAssertTrue(try catalog.apply(page(#"{"type":"catalog_page","revision":5,"items":[{"kind":"workspace","workspace":{"id":"33333333-3333-4333-8333-333333333333","name":"New","kind":"standalone"}}],"nextCursor":null,"hostOnline":false}"#)))
        XCTAssertEqual(catalog.revision, 5)
        XCTAssertEqual(catalog.workspaces.map(\.name), ["New"])
        XCTAssertTrue(catalog.sessions.isEmpty)
        XCTAssertFalse(catalog.hostOnline)
    }

    func testDuplicateAcrossPagesIsRejectedWithoutChangingCatalog() throws {
        var catalog = WorkbenchCatalog()
        let workspace = #"{"type":"catalog_page","revision":2,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}}],"nextCursor":"2:1","hostOnline":true}"#
        let duplicate = #"{"type":"catalog_page","revision":2,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Conflicting name","kind":"project"}}],"nextCursor":null,"hostOnline":true}"#
        try catalog.apply(page(workspace))

        XCTAssertThrowsError(try catalog.apply(page(duplicate))) { error in
            XCTAssertEqual(error as? CatalogFault, .duplicateWorkspace)
        }
        XCTAssertEqual(catalog.workspaces.count, 1)
        XCTAssertEqual(catalog.nextCursor, "2:1")
    }

    func testNameSearchIsLimitedToCatalogMetadata() throws {
        var catalog = WorkbenchCatalog()
        let json = #"{"type":"catalog_page","revision":1,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo Lab","kind":"project"}},{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"Phone UI","availability":"stopped"}}],"nextCursor":null,"hostOnline":true}"#
        try catalog.apply(page(json))

        let matches = catalog.searchNames("PHONE")
        XCTAssertEqual(matches.count, 1)
        guard case .session(let session) = matches[0] else { return XCTFail("Expected a session name result") }
        XCTAssertEqual(session.name, "Phone UI")
        XCTAssertTrue(catalog.searchNames("not in catalog").isEmpty)
    }

    private func page(_ json: String) throws -> CatalogPage {
        try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
    }
}
