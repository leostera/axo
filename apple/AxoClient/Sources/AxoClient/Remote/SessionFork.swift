import AxoProtocol
import Foundation

/// The account's published transcript boundary, not the cursor of the page on screen.
public struct SessionForkSnapshot: Equatable, Sendable {
  public let hostID: UUID
  public let sessionID: SessionID
  public let epoch: Int64
  public let head: Int64

  public init(_ source: RemoteSession) throws {
    guard source.agent == .pi, source.hasAgent != false else {
      throw SessionForkError.unsupportedAgent
    }
    guard let epoch = source.epoch, epoch > 0, let head = source.head, head > 0 else {
      throw SessionForkError.historyUnavailable
    }
    hostID = source.hostId
    sessionID = source.sessionId
    self.epoch = epoch
    self.head = head
  }
}

public enum SessionForkError: LocalizedError {
  case unsupportedAgent
  case historyUnavailable
  case destinationUnavailable
  case selectionChanged

  public var errorDescription: String? {
    switch self {
    case .unsupportedAgent: "Only Pi sessions can be forked."
    case .historyUnavailable: "This session’s Pi history is not available to fork yet."
    case .destinationUnavailable: "The destination machine is no longer available."
    case .selectionChanged: "This session is no longer available to fork here."
    }
  }

  public static func needsDestinationFolder(_ error: Error) -> Bool {
    guard let rpc = error as? AxoClientError,
      case .serverRejected(_, let message) = rpc else { return false }
    return message == "Choose a destination folder"
  }
}

extension RemoteSession {
  func forkChild(of sourceID: SessionID, on destinationID: UUID) throws -> RemoteSession {
    guard hostId == destinationID, sessionId != sourceID else {
      throw AxoClientError.invalidResponse("the host did not return a new Session on the destination")
    }
    return self
  }
}
