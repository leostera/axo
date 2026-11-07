import CryptoKit
import Foundation

/// A file attached to a prompt (RFD0030): an asset in the account, named by the SHA-256 of its
/// bytes. The Mac fetches it, checks it, and hands it to Pi with the prompt.
public struct Attachment: Codable, Equatable, Hashable, Sendable {
  /// `sha256:<64 hex digits>`.
  public let asset: String
  public let name: String
  public let mimeType: String
  public let size: Int

  public init(asset: String, name: String, mimeType: String, size: Int) {
    self.asset = asset
    self.name = name
    self.mimeType = mimeType
    self.size = size
  }

  /// The most one prompt carries.
  public static let maxPerPrompt = 8
  /// The most one file may be.
  public static let maxBytes = 100 * 1024 * 1024
  /// Types the account keeps as they are; anything else is kept as `application/octet-stream`.
  public static let knownTypes: Set<String> = [
    "image/png", "image/jpeg", "image/gif", "image/webp", "image/heic", "application/pdf", "text/plain",
    "text/markdown", "text/csv", "application/json", "application/zip", "application/octet-stream",
  ]

  /// A type the account takes: one it knows, or `application/octet-stream`.
  public static func storedType(_ mimeType: String) -> String {
    let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    return knownTypes.contains(base) ? base : "application/octet-stream"
  }

  /// A file name the account takes: no slashes or control characters, at most 255 bytes.
  public static func safeName(_ name: String) -> String {
    var kept = ""
    for character in name {
      let replaced: Character =
        character == "/" || character == "\\" || character.unicodeScalars.contains { $0.properties.generalCategory == .control }
        ? "_" : character
      guard (kept + String(replaced)).utf8.count <= 255 else { break }
      kept.append(replaced)
    }
    kept = kept.trimmingCharacters(in: .whitespaces)
    return kept.isEmpty || kept == "." || kept == ".." ? "file" : kept
  }
}

/// Uploads files to the account's assets over HTTPS, with the phone's session token.
public struct AssetsClient: Sendable {
  private let endpoint: RelayEndpoint
  private let tokens: any SessionTokenProvider
  private let loader: any HTTPDataLoading

  public init(
    endpoint: RelayEndpoint = .production,
    tokens: any SessionTokenProvider,
    loader: any HTTPDataLoading = RelayCredentials.makeURLSession()
  ) {
    self.endpoint = endpoint
    self.tokens = tokens
    self.loader = loader
  }

  /// Uploads `data` as `name`; what a prompt names it by. The account answers at once if it
  /// already has these bytes.
  public func upload(_ data: Data, name: String, mimeType: String) async throws -> Attachment {
    guard data.count <= Attachment.maxBytes else {
      throw AppsRefusal(status: 413, message: "Files can be at most 100 MB.")
    }
    let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let name = Attachment.safeName(name)
    var request = URLRequest(url: endpoint.assetURL(hex: hex))
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Attachment.storedType(mimeType), forHTTPHeaderField: "Content-Type")
    request.setValue(
      name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "file",
      forHTTPHeaderField: "X-Axo-Asset-Name")
    request.httpBody = data
    request = try await RelayCredentials.authorize(request, with: tokens)
    let (body, response): (Data, HTTPURLResponse)
    do {
      (body, response) = try await loader.load(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as AxoClientError {
      throw error
    } catch {
      throw RelayError.unreachable(error.localizedDescription)
    }
    struct Refusal: Decodable { let error: String }
    switch response.statusCode {
    case 200..<300:
      do {
        return try JSONDecoder().decode(Attachment.self, from: body)
      } catch {
        throw AxoClientError.invalidResponse("the account did not say what it kept")
      }
    case 401:
      throw RelayError.signInRequired
    default:
      let message = (try? JSONDecoder().decode(Refusal.self, from: body).error) ?? "Upload failed (\(response.statusCode))"
      throw AppsRefusal(status: response.statusCode, message: message)
    }
  }
}
