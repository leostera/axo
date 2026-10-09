import CryptoKit
import Foundation
import XCTest
@testable import AxoCore

private actor FileReplies {
    struct Reply: Sendable { let status: Int; let body: Data }
    private var replies: [String: Reply] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var paths: [String: Reply] = [:]
    func registerPath(_ host: String, _ path: String, body: Data) { paths[host + path] = Reply(status: 200, body: body) }
    func register(_ host: String, status: Int, body: Data) { replies[host] = Reply(status: status, body: body); requests[host] = [] }
    func receive(_ request: URLRequest) -> Reply {
        let host = request.url!.host!
        requests[host, default: []].append(request)
        return paths[host + request.url!.path] ?? replies[host] ?? Reply(status: 503, body: Data())
    }
    func received(_ host: String) -> [URLRequest] { requests[host] ?? [] }
}

private final class FilesURLProtocol: URLProtocol, @unchecked Sendable {
    static let replies = FileReplies()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            let reply = await Self.replies.receive(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class SessionFilesTests: XCTestCase {
    private var fileRecord: [String: Any] { ["id": "00000000-0000-4000-8000-000000000001", "sessionId": "session", "filename": "report.md", "mediaType": "text/markdown", "byteLength": 12,
        "sha256": String(repeating: "a", count: 64), "origin": "host", "createdAt": 0, "state": "ready"] }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FilesURLProtocol.self]
        return config
    }

    @MainActor
    func testPublicationUploadsDirectlyToR2WithoutForwardingAccessCredentials() async throws {
        let host = "\(UUID().uuidString.lowercased()).test"
        let r2Host = String(repeating: "a", count: 32) + ".r2.cloudflarestorage.com"
        let content = Data("Shared bytes".utf8)
        let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let pending = fileRecord.merging(["origin": "phone", "state": "pending", "byteLength": content.count, "sha256": sha]) { _, new in new }
        let id = try XCTUnwrap(pending["id"] as? String)
        let ready = pending.merging(["state": "ready"]) { _, new in new }
        await FilesURLProtocol.replies.register(host, status: 200, body: try JSONSerialization.data(withJSONObject: pending))
        await FilesURLProtocol.replies.register(r2Host, status: 200, body: Data())
        let grant: [String: Any] = ["file": pending, "upload": [
            "url": "https://\(r2Host)/test-files/files/\(id)/attempt?X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "expiresAt": Int64(Date().timeIntervalSince1970 * 1000) + 60_000,
            "headers": ["Content-Type": "text/markdown", "Content-Length": String(content.count), "If-None-Match": "*", "x-amz-checksum-sha256": Data(SHA256.hash(data: content)).base64EncodedString()]]]
        await FilesURLProtocol.replies.registerPath(host, "/files/sessions/session/uploads/\(id)/authorize", body: try JSONSerialization.data(withJSONObject: grant))
        await FilesURLProtocol.replies.registerPath(host, "/files/sessions/session/uploads/\(id)/complete", body: try JSONSerialization.data(withJSONObject: ready))
        let config = configuration()
        config.httpAdditionalHeaders = ["Authorization": "must-not-reach-r2"]
        let client = SessionFilesClient(endpoint: try RelayEndpoint("https://\(host)"), cookie: "private-access-cookie", configuration: config)
        client.selectSession("session")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("report.md")
        try content.write(to: source)
        let staged = await client.addFile(source)
        let draftID = try XCTUnwrap(staged)
        defer { client.removeDraft(draftID) }
        client.retryUpload(draftID)
        let deadline = Date().addingTimeInterval(5)
        while client.currentDrafts.first?.isUploading == true && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(client.currentDrafts.first?.error)
        XCTAssertEqual(client.readyDrafts.first?.id, id)
        let direct = await FilesURLProtocol.replies.received(r2Host)
        XCTAssertEqual(direct.count, 1)
        XCTAssertEqual(direct.first?.httpMethod, "PUT")
        XCTAssertNil(direct.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(direct.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(direct.first?.value(forHTTPHeaderField: "If-None-Match"), "*")
        let metadata = await FilesURLProtocol.replies.received(host)
        XCTAssertEqual(metadata.count, 3)
        XCTAssertFalse(metadata.contains { $0.httpMethod == "PUT" })
    }

    func testAttachmentWireMetadataAndOnlyFileIDsInPrompts() throws {
        let file = try JSONDecoder().decode(SharedFile.self, from: JSONSerialization.data(withJSONObject: fileRecord))
        try file.validate()
        let command = PhoneCommand.prompt(id: "c", session: "session", text: "", attachmentIds: [file.id])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        XCTAssertEqual(body["attachmentIds"] as? [String], [file.id])
        XCTAssertNil(body["sha256"])
        XCTAssertNil(body["data"])
        let event = try RelayEvent.decode(JSONSerialization.data(withJSONObject: ["type": "files_changed", "sessionId": "session", "revision": 3]))
        guard case .filesChanged("session", 3) = event else { return XCTFail("Expected file invalidation") }
    }

    func testNativeFileMetadataValidationRejectsPathsAndOversizedFiles() throws {
        for change in [["filename": "../bad"], ["filename": "bad\nname"], ["byteLength": 26 * 1024 * 1024], ["mediaType": "text/html"], ["id": "not-a-file-id"]] as [[String: Any]] {
            let value = fileRecord.merging(change) { _, new in new }
            XCTAssertThrowsError(try JSONDecoder().decode(SharedFile.self, from: JSONSerialization.data(withJSONObject: value)))
        }
    }

    @MainActor
    func testFileListFetchIsExplicitAuthenticatedAndInvalidationDoesNotHydrateHistory() async throws {
        let host = "\(UUID().uuidString.lowercased()).test"
        let endpoint = try RelayEndpoint("https://\(host)")
        let payload = try JSONSerialization.data(withJSONObject: ["files": [fileRecord], "nextCursor": "20", "revision": 1])
        await FilesURLProtocol.replies.register(host, status: 200, body: payload)
        let client = SessionFilesClient(endpoint: endpoint, cookie: "test-cookie", configuration: configuration())
        client.selectSession("session")
        client.invalidate(sessionId: "session")
        let before = await FilesURLProtocol.replies.received(host)
        XCTAssertTrue(before.isEmpty)
        await client.loadFiles()
        XCTAssertEqual(client.files.count, 1)
        XCTAssertEqual(client.nextCursor, "20")
        client.invalidate(sessionId: "session")
        let requests = await FilesURLProtocol.replies.received(host)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cookie"), "CF_Authorization=test-cookie")
        XCTAssertEqual(requests[0].url?.path, "/files/sessions/session/files")
        XCTAssertTrue(client.isStale)
    }

    func testDraftMigrationPreservesInterruptedUploadsWithoutMakingThemReady() throws {
        let record: [String: Any] = ["id": UUID().uuidString, "sessionId": "session", "filename": "report.md", "source": "file:///tmp/report.md",
            "isUploading": true, "progress": 0.5]
        let draft = try JSONDecoder().decode(DraftFile.self, from: JSONSerialization.data(withJSONObject: record))
        guard case .uploading(let progress, nil) = draft.transfer else { return XCTFail("Expected preserved interrupted transfer") }
        XCTAssertEqual(progress, 0.5)
        XCTAssertNil(draft.readyFile)
    }

    func testSavedReadyStateCannotWrapAnUnpublishedReservation() throws {
        let pending = try JSONDecoder().decode(SharedFile.self, from: JSONSerialization.data(withJSONObject: fileRecord.merging(["state": "pending"]) { _, new in new }))
        var draft = DraftFile(id: UUID(), sessionId: "session", filename: "report.md", source: URL(fileURLWithPath: "/tmp/report.md"))
        draft.transfer = .ready(pending)
        XCTAssertThrowsError(try JSONDecoder().decode(DraftFile.self, from: JSONEncoder().encode(draft)))
    }

    @MainActor
    func testSelectingFileOnlyStagesADurableLocalDraftWithoutPublishing() async throws {
        let host = "\(UUID().uuidString.lowercased()).test"
        await FilesURLProtocol.replies.register(host, status: 503, body: Data())
        let client = SessionFilesClient(endpoint: try RelayEndpoint("https://\(host)"), cookie: "test-cookie", configuration: configuration())
        client.selectSession("session")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).md")
        try Data("Not shared".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = await client.addFile(source)
        let id = try XCTUnwrap(staged)
        try await Task.sleep(for: .milliseconds(100))
        let requests = await FilesURLProtocol.replies.received(host)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(client.currentDrafts.first?.file)
        XCTAssertFalse(client.currentDrafts[0].isUploading)
        XCTAssertFalse(client.canSubmitDrafts)
        client.removeDraft(id)
    }

    @MainActor
    func testOpeningRechecksDeletionAndExactImmutableIdentityBeforeAnyDownload() async throws {
        let host = "\(UUID().uuidString.lowercased()).test"
        let endpoint = try RelayEndpoint("https://\(host)")
        let client = SessionFilesClient(endpoint: endpoint, cookie: "test-cookie", configuration: configuration())
        client.selectSession("session")
        let file = try JSONDecoder().decode(SharedFile.self, from: JSONSerialization.data(withJSONObject: fileRecord))
        for change in [["state": "deleted"], ["sessionId": "other"], ["filename": "changed.md"]] {
            let changed = fileRecord.merging(change) { _, new in new }
            await FilesURLProtocol.replies.register(host, status: 200, body: try JSONSerialization.data(withJSONObject: changed))
            do { _ = try await client.open(file); XCTFail("An unavailable or changed snapshot must not open") }
            catch { XCTAssertTrue(error.localizedDescription.contains("deleted, changed")) }
            let requests = await FilesURLProtocol.replies.received(host)
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(requests[0].url!.path.hasSuffix("/content"))
        }
    }

    @MainActor
    func testFailedUploadKeepsDraftSourceAcrossClientRecreationWithoutAutoReplay() async throws {
        let host = "\(UUID().uuidString.lowercased()).test"
        let endpoint = try RelayEndpoint("https://\(host)")
        await FilesURLProtocol.replies.register(host, status: 503, body: Data(#"{"message":"Storage disabled for test"}"#.utf8))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString).md")
        try Data("Unsent document".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let client = SessionFilesClient(endpoint: endpoint, cookie: "test-cookie", configuration: configuration())
        client.selectSession("session")
        await client.addFile(source)
        let id = try XCTUnwrap(client.currentDrafts.first?.id)
        client.retryUpload(id)
        let deadline = Date().addingTimeInterval(3)
        while client.currentDrafts.first?.isUploading == true && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(client.currentDrafts.count, 1)
        XCTAssertEqual(client.currentDrafts.first?.error, "Storage disabled for test")
        XCTAssertFalse(client.canSubmitDrafts)
        let sourceCopy = try XCTUnwrap(client.currentDrafts.first?.source)
        XCTAssertEqual(try String(contentsOf: sourceCopy, encoding: .utf8), "Unsent document")
        let restored = SessionFilesClient(endpoint: endpoint, cookie: "test-cookie", configuration: configuration())
        XCTAssertEqual(restored.currentDrafts.count, 1)
        XCTAssertFalse(restored.currentDrafts[0].isUploading)
        let count = await FilesURLProtocol.replies.received(host).count
        try await Task.sleep(for: .milliseconds(100))
        let after = await FilesURLProtocol.replies.received(host).count
        XCTAssertEqual(after, count)
        restored.removeDraft(restored.currentDrafts[0].id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceCopy.path))
    }
}
