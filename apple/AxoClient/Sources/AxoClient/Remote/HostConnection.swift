import AxoProtocol
import Foundation

/// One host's commands, through the account's socket (RFD0018): the same shape as
/// `AxodConnection`, so a client treats "this Mac" and a remote host alike. Calls name the host and
/// the run of it they mean; the relay refuses a call for an older run ("Stale host") instead of
/// acting on the wrong one, and refuses one for a host that is offline instead of queueing it.
public struct HostConnection: Sendable {
  public let host: RemoteHostRef
  private let account: AccountConnection

  public init(account: AccountConnection, host: RemoteHostRef) {
    self.account = account
    self.host = host
  }

  // MARK: - Workspaces and Sessions

  public func workspaces() async throws -> [RemoteWorkspace] {
    try await call("axo.remote.workspace.list", Target(target: host), as: RemoteWorkspaceList.self)
      .workspaces
  }

  public func createSession() async throws -> RemoteSession {
    try await session(from: call("axo.remote.session.create", Target(target: host)))
  }

  public func createSession(inWorkspace workspaceID: UUID) async throws -> RemoteSession {
    try await session(
      from: call(
        "axo.remote.workspace.session.create",
        WorkspaceTarget(target: host, workspaceId: workspaceID)))
  }

  /// Closes a Session; the host may answer with the replacement it opened if that was the last.
  public func closeSession(_ id: SessionID) async throws -> RemoteSession? {
    let closed: ClosedSession = try await call(
      "axo.remote.session.close", SessionTarget(target: host, sessionId: id))
    guard closed.closed, closed.sessionId == id else {
      throw AxoClientError.invalidResponse("the host did not close that Session")
    }
    return closed.replacement
  }

  public func renameSession(_ id: SessionID, to name: String) async throws {
    try expectSaved(
      await call("axo.remote.session.rename", RenameTarget(target: host, sessionId: id, name: name)))
  }

  public func setLayout(_ layout: SessionLayout, for id: SessionID) async throws {
    try expectSaved(
      await call(
        "axo.remote.session.layout.set", LayoutTarget(target: host, sessionId: id, layout: layout)))
  }

  // MARK: - Terminals

  public func createShell(in id: SessionID) async throws -> ShellID {
    let created: CreatedShell = try await call(
      "axo.remote.shell.create", SessionTarget(target: host, sessionId: id))
    guard created.hostId == host.hostId, created.sessionId == id else {
      throw AxoClientError.invalidResponse("the host created a terminal elsewhere")
    }
    return created.shellId
  }

  public func closeShell(_ shell: ShellID, in id: SessionID) async throws {
    let closed: ClosedShell = try await call(
      "axo.remote.shell.close", ShellTarget(target: host, sessionId: id, shellId: shell))
    guard closed.closed, closed.hostId == host.hostId, closed.sessionId == id,
      closed.shellId == shell
    else { throw AxoClientError.invalidResponse("the host did not close that terminal") }
  }

  /// Sends a prompt to the Session's Pi. `commandId` makes it one command however often it is sent:
  /// the Session's Pi takes it at most once and writes a receipt carrying the id just before it
  /// (RFD0024). The host refuses it when the Session has no Pi running. `attachments` are assets
  /// already in the account (RFD0030): the Mac fetches them all before Pi gets the prompt, or
  /// refuses it.
  public func promptPi(in id: SessionID, text: String, commandId: UUID, attachments: [Attachment] = []) async throws {
    let accepted: PromptAccepted = try await call(
      "axo.remote.session.prompt",
      PromptTarget(
        target: host, sessionId: id, text: text, commandId: commandId.uuidString.lowercased(),
        attachments: attachments.isEmpty ? nil : attachments))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that prompt")
    }
  }

  /// Stops the Session's running turn, if it is still the one `turnId` (the entry id of its user
  /// message) names; a turn that started since carries on. Says whether one stopped.
  @discardableResult
  public func stopPiTurn(in id: SessionID, turnId: String) async throws -> Bool {
    let result: StopResult = try await call(
      "axo.remote.session.stop", StopTarget(target: host, sessionId: id, turnId: turnId))
    return result.stopped
  }

  /// A key pressed in the Session's Pi, as a person at the Mac would press it.
  public enum PiKey: String, Encodable, Sendable {
    /// Stops the reply in progress, or declines Pi's question.
    case escape
    /// Accepts Pi's question.
    case enter
  }

  /// Presses `key` in the Session's Pi. The host refuses it when the Session has no Pi running.
  public func pressPiKey(_ key: PiKey, in id: SessionID) async throws {
    let accepted: PromptAccepted = try await call(
      "axo.remote.session.key", KeyTarget(target: host, sessionId: id, key: key))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that key")
    }
  }

  /// Types into a terminal. `sequence` numbers this client's input, starting at 0.
  public func sendInput(_ bytes: Data, to shell: ShellID, in id: SessionID, sequence: UInt64)
    async throws
  {
    let accepted: InputAccepted = try await call(
      "axo.remote.terminal.input",
      InputTarget(
        target: host, sessionId: id, shellId: shell, sequence: sequence,
        data: bytes.base64EncodedString()))
    guard accepted.accepted, accepted.sequence == sequence else {
      throw AxoClientError.invalidResponse("the host did not accept that input")
    }
  }

  public func resize(_ shell: ShellID, in id: SessionID, rows: Int, columns: Int) async throws {
    let accepted: ResizeAccepted = try await call(
      "axo.remote.terminal.resize",
      ResizeTarget(target: host, sessionId: id, shellId: shell, rows: rows, columns: columns))
    guard accepted.accepted else {
      throw AxoClientError.invalidResponse("the host did not accept that size")
    }
  }

  // MARK: - Calls

  private func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
    _ method: String, _ params: Params, as: Result.Type = Result.self
  ) async throws -> Result {
    try await account.command(method, on: host.hostId, params: params)
  }

  private func session(from created: CreatedSession) throws -> RemoteSession {
    guard created.session.hostId == host.hostId else {
      throw AxoClientError.invalidResponse("the host created a Session elsewhere")
    }
    return created.session
  }

  private func expectSaved(_ saved: Saved) throws {
    guard saved.saved else {
      throw AxoClientError.invalidResponse("the host did not save the change")
    }
  }
}

// MARK: - Wire shapes

private struct Target: Encodable, Sendable { let target: RemoteHostRef }
private struct WorkspaceTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let workspaceId: UUID

  private enum CodingKeys: String, CodingKey { case target, workspaceId }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(workspaceId.uuidString.lowercased(), forKey: .workspaceId)
  }
}
private struct SessionTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
}
private struct ShellTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
}
private struct RenameTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let name: String
}
private struct PromptTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let text: String
  let commandId: String
  let attachments: [Attachment]?

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(text, forKey: .text)
    try container.encode(commandId, forKey: .commandId)
    try container.encodeIfPresent(attachments, forKey: .attachments)
  }

  enum CodingKeys: String, CodingKey { case target, sessionId, text, commandId, attachments }
}
private struct StopTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let turnId: String
}
private struct StopResult: Decodable, Sendable {
  let stopped: Bool
}
private struct KeyTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let key: HostConnection.PiKey
}
private struct LayoutTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let layout: SessionLayout
}
private struct InputTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
  let sequence: UInt64
  let data: String
}
private struct ResizeTarget: Encodable, Sendable {
  let target: RemoteHostRef
  let sessionId: SessionID
  let shellId: ShellID
  let rows: Int
  let columns: Int
}

private struct CreatedSession: Decodable, Sendable { let session: RemoteSession }
private struct ClosedSession: Decodable, Sendable {
  let closed: Bool
  let sessionId: SessionID
  let replacement: RemoteSession?
}
private struct CreatedShell: Decodable, Sendable {
  let hostId: UUID
  let sessionId: SessionID
  let shellId: ShellID
}
private struct ClosedShell: Decodable, Sendable {
  let closed: Bool
  let hostId: UUID
  let sessionId: SessionID
  let shellId: ShellID
}
private struct Saved: Decodable, Sendable { let saved: Bool }
private struct InputAccepted: Decodable, Sendable {
  let accepted: Bool
  let sequence: UInt64
}
private struct PromptAccepted: Decodable, Sendable { let accepted: Bool }
private struct ResizeAccepted: Decodable, Sendable { let accepted: Bool }
