import Foundation

/// Authenticated metadata endpoint for the existing private file service.
/// It is deliberately separate from both the central session authority and its RPC endpoint.
public struct SessionFilesEndpoint: Equatable, Sendable {
    public let baseURL: URL

    public init(_ origin: String) throws {
        guard let url = URL(string: origin), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw SessionFilesEndpointError.invalidEndpoint
        }
        baseURL = url
    }
}

public enum SessionFilesEndpointError: Error, Equatable, Sendable {
    case invalidEndpoint
}
