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

    func testCatalogCacheRoundTripsCompleteMetadataWithoutClaimingHostIsOnline() throws {
        var catalog = WorkbenchCatalog()
        let complete = #"{"type":"catalog_page","revision":9,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}},{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"Phone","conversationId":"pi-phone","availability":"running"}}],"nextCursor":null,"hostOnline":true}"#
        try catalog.apply(page(complete))
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = WorkbenchCatalogCache(fileURL: cacheURL)

        try cache.save(catalog)
        let restored = try XCTUnwrap(cache.load())

        XCTAssertEqual(restored.snapshot(), catalog.snapshot())
        XCTAssertFalse(restored.hostOnline, "A disk cache cannot assert that the Mac is currently online")
    }

    func testCatalogCacheDoesNotReplaceGoodCacheWithAnIncompletePage() throws {
        var catalog = WorkbenchCatalog()
        let partial = #"{"type":"catalog_page","revision":9,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}}],"nextCursor":"9:1","hostOnline":true}"#
        try catalog.apply(page(partial))
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = WorkbenchCatalogCache(fileURL: cacheURL)

        try cache.save(catalog)

        XCTAssertNil(try cache.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func testCatalogSnapshotRejectsSessionsOutsideTheCachedWorkspaceSet() throws {
        let session = try XCTUnwrap(page(#"{"type":"catalog_page","revision":1,"items":[{"kind":"workspace","workspace":{"id":"11111111-1111-4111-8111-111111111111","name":"Axo","kind":"project"}},{"kind":"session","session":{"id":"22222222-2222-4222-8222-222222222222","workspaceId":"11111111-1111-4111-8111-111111111111","name":"Phone","availability":"stopped"}}],"nextCursor":null,"hostOnline":false}"#).items.compactMap { item -> CatalogSession? in
            if case .session(let session) = item { session } else { nil }
        }.first)
        let snapshot = WorkbenchCatalogSnapshot(revision: 1, workspaces: [], sessions: [session])

        XCTAssertThrowsError(try WorkbenchCatalog(snapshot: snapshot)) { error in
            XCTAssertEqual(error as? CatalogFault, .invalidMembership)
        }
    }

    func testCatalogCacheRejectsOversizedFiles() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try Data(repeating: 0, count: WorkbenchCatalogCache.maximumBytes + 1).write(to: cacheURL)

        XCTAssertThrowsError(try WorkbenchCatalogCache(fileURL: cacheURL).load()) { error in
            XCTAssertEqual(error as? CatalogCacheFault, .tooLarge)
        }
    }

    private func page(_ json: String) throws -> CatalogPage {
        try JSONDecoder().decode(CatalogPage.self, from: Data(json.utf8))
    }
}
