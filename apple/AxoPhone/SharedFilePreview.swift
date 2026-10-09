#if DEBUG
import AxoCore
import CryptoKit
import Foundation

/// Synthetic, in-process HTTP fixture for simulator UI tests; never connects to a relay.
@MainActor
enum SharedFilePreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--axo-file-draft-preview") }
    static func makeClient() async throws -> SessionFilesClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilePreviewProtocol.self]
        let client = SessionFilesClient(endpoint: try RelayEndpoint("https://files-preview.invalid"), cookie: "preview-cookie", configuration: configuration)
        client.cancelAllUploads()
        for draft in client.drafts { client.removeDraft(draft.id) }
        client.selectSession("preview-session")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("draft-report.md")
        try FilePreviewProtocol.content.write(to: source)
        await client.addFile(source)
        return client
    }
}

private actor PreviewFileServer {
    struct Reply: Sendable { let body: Data; let mediaType: String }
    private var state = "pending"
    private var revision = 1
    func respond(_ request: URLRequest) throws -> Reply {
        let path = request.url!.path
        if request.httpMethod == "PUT" { state = "ready"; revision += 1 }
        if request.httpMethod == "DELETE" { state = "deleted"; revision += 1 }
        if path.hasSuffix("/content") && request.httpMethod == "GET" { return Reply(body: FilePreviewProtocol.content, mediaType: "text/markdown") }
        let file: [String: Any] = ["id": "00000000-0000-4000-8000-000000000002", "sessionId": "preview-session", "filename": "draft-report.md",
            "mediaType": "text/markdown", "byteLength": FilePreviewProtocol.content.count,
            "sha256": SHA256.hash(data: FilePreviewProtocol.content).map { String(format: "%02x", $0) }.joined(),
            "origin": "phone", "createdAt": 0, "state": state]
        let body: [String: Any] = path.hasSuffix("/files") ? ["files": state == "pending" ? [] : [file], "nextCursor": NSNull(), "revision": revision] : file
        return Reply(body: try JSONSerialization.data(withJSONObject: body), mediaType: "application/json")
    }
}

private final class FilePreviewProtocol: URLProtocol, @unchecked Sendable {
    static let content = Data("# Synthetic shared report\n\nThis document exists only in the simulator fixture.\n".utf8)
    private static let server = PreviewFileServer()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "files-preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            do {
                let reply = try await Self.server.respond(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mediaType, "Cache-Control": "private, no-store"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
#endif
