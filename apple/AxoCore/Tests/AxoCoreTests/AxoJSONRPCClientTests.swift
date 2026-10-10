import AxoProtocol
import Foundation
import XCTest
@testable import AxoCore

final class AxoJSONRPCClientTests: XCTestCase {
    override func tearDown() {
        HTTPResponseStore.shared.clear()
        super.tearDown()
    }

    func testPrivateEndpointUsesDedicatedAudienceAndRejectsMalformedOrExpiredCookies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let endpoint = AxoControlPlaneEndpoint.production
        XCTAssertEqual(endpoint.rpcURL.absoluteString, "https://api.axo.leostera.dev/v1/rpc")
        XCTAssertEqual(
            endpoint.clientSocketURL(machineID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!).absoluteString,
            "wss://api.axo.leostera.dev/v1/machines/11111111-1111-4111-8111-111111111111/client"
        )

        let valid = try AxoControlPlaneAccessCookie(jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 1_800_000_060), now: now)
        XCTAssertEqual(valid.expiresAt, Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertThrowsError(try AxoControlPlaneAccessCookie(jwt(audience: "legacy-relay-audience", expiration: 1_800_000_060), now: now))
        XCTAssertThrowsError(try AxoControlPlaneAccessCookie(jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 1_799_999_999), now: now))
        XCTAssertThrowsError(try AxoControlPlaneAccessCookie("not-a-jwt", now: now))
        XCTAssertThrowsError(try AxoControlPlaneEndpoint("http://api.axo.leostera.dev"))
        XCTAssertThrowsError(try AxoControlPlaneEndpoint("https://user@api.axo.leostera.dev"))
        XCTAssertThrowsError(try AxoControlPlaneEndpoint("https://api.axo.leostera.dev/v1/rpc"))
    }

    func testHTTPDiscoveryUsesOnlyCFAuthorizationCookieAndCorrelatesResponse() async throws {
        let expectedCookie = jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 4_102_444_800)
        HTTPResponseStore.shared.install { request in
            guard let body = requestBody(request),
                  let call = try? JSONDecoder().decode(RPCRequest.self, from: body),
                  call.method == AxoProtocol.Method.listMachines,
                  case .string(let id)? = call.id else {
                return .init(status: 400, body: Data())
            }
            return .init(status: 200, body: Data(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"machines":[]}}"#.utf8))
        }

        let result = try await makeClient().callHTTP(
            endpoint: .production,
            accessCookie: try AxoControlPlaneAccessCookie(expectedCookie),
            method: AxoProtocol.Method.listMachines,
            parameters: EmptyRPCParameters()
        )
        XCTAssertEqual(try AxoProtocolResultValidator.machineList(result).machines, [])
        let request = try XCTUnwrap(HTTPResponseStore.shared.lastRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.axo.leostera.dev/v1/rpc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=\(expectedCookie)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"))
    }

    func testHTTPUnauthorizedAndMismatchedRPCIDsFailClosed() async throws {
        HTTPResponseStore.shared.install { _ in .init(status: 401, body: Data("expired".utf8), contentType: "text/plain") }
        do {
            _ = try await makeClient().callHTTP(
                endpoint: .production,
                accessCookie: try AxoControlPlaneAccessCookie(jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 4_102_444_800)),
                method: AxoProtocol.Method.listMachines,
                parameters: EmptyRPCParameters()
            )
            XCTFail("Expected an expired Access response")
        } catch let error as AxoJSONRPCClientError {
            XCTAssertEqual(error, .unauthorized(statusCode: 401))
        }

        HTTPResponseStore.shared.install { _ in
            .init(status: 200, body: Data(#"{"jsonrpc":"2.0","id":"wrong","result":{"machines":[]}}"#.utf8))
        }
        do {
            _ = try await makeClient().callHTTP(
                endpoint: .production,
                accessCookie: try AxoControlPlaneAccessCookie(jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 4_102_444_800)),
                method: AxoProtocol.Method.listMachines,
                parameters: EmptyRPCParameters()
            )
            XCTFail("Expected mismatched response IDs to be rejected")
        } catch let error as AxoJSONRPCClientError {
            XCTAssertEqual(error, .mismatchedResponseID)
        }
    }

    func testHTTPResponseFrameBoundIsEnforcedBeforeJSONDecoding() async throws {
        HTTPResponseStore.shared.install { _ in
            .init(status: 200, body: Data(repeating: 32, count: AxoProtocolCodec.maximumFrameBytes + 1))
        }
        do {
            _ = try await makeClient().callHTTP(
                endpoint: .production,
                accessCookie: try AxoControlPlaneAccessCookie(jwt(audience: AxoControlPlaneEndpoint.accessAudience, expiration: 4_102_444_800)),
                method: AxoProtocol.Method.listMachines,
                parameters: EmptyRPCParameters()
            )
            XCTFail("Expected oversized response rejection")
        } catch let error as AxoJSONRPCClientError {
            XCTAssertEqual(error, .frameTooLarge)
        }
    }

    private func makeClient() -> AxoJSONRPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return AxoJSONRPCClient(session: URLSession(configuration: configuration))
    }

    private func jwt(audience: String, expiration: Int) -> String {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URL
        let payload = Data(#"{"aud":"\#(audience)","exp":\#(expiration),"type":"app"}"#.utf8).base64URL
        return "\(header).\(payload).signature"
    }
}

private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private struct StubHTTPResponse: Sendable {
    let status: Int
    let body: Data
    var contentType = "application/json"
}

private final class HTTPResponseStore: @unchecked Sendable {
    static let shared = HTTPResponseStore()
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> StubHTTPResponse = { _ in .init(status: 500, body: Data()) }
    private var recordedRequest: URLRequest?

    func install(_ handler: @escaping @Sendable (URLRequest) -> StubHTTPResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func response(for request: URLRequest) -> StubHTTPResponse {
        lock.lock()
        let handler = self.handler
        recordedRequest = request
        lock.unlock()
        return handler(request)
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    func clear() {
        install { _ in .init(status: 500, body: Data()) }
    }
}

private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let stub = HTTPResponseStore.shared.response(for: request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
