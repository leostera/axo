import AxoRPC

/// What the connected Axod offers. Negotiated on first use, once per connection, and forgotten
/// when the connection is renewed, because Axod may have been upgraded or restarted in between.
@MainActor
final class AxodCapabilities {
  /// Methods every supported Axod must offer.
  static let requiredMethods: Set<AxodMethodName> = [
    .sessionList, .workspaceList, .workspaceCreate, .workspaceSessionCreate, .sessionSubscribe,
    .sessionEventsNext, .sessionUnsubscribe,
  ]

  private let client: AxodClient
  /// The methods this Axod offers; `nil` until negotiated. Names Axo doesn't know are dropped:
  /// it has no way to call them.
  private var methods: Set<AxodMethodName>?

  init(client: AxodClient) {
    self.client = client
  }

  /// The connection was renewed; negotiate again before the next check.
  func forget() {
    methods = nil
  }

  /// Negotiates unless already done on this connection. Throws when this Axod speaks another
  /// protocol version or lacks a required method.
  func negotiate() async throws {
    guard methods == nil else { return }
    let negotiation = try await client.negotiate()
    let offered = Set(negotiation.methods.compactMap(AxodMethodName.init(rawValue:)))
    guard negotiation.protocolVersion == UnixSocketRPC.protocolVersion,
      Self.requiredMethods.isSubset(of: offered)
    else {
      throw SessionCommandError(
        "The running axod is incompatible with this version of Axo. Restart axod from the menu bar.")
    }
    methods = offered
  }

  func supports(_ method: AxodMethodName) async throws -> Bool {
    try await negotiate()
    return methods?.contains(method) == true
  }

  /// Throws, leaving everything unchanged, when this Axod lacks `method`.
  func require(_ method: AxodMethodName) async throws {
    guard try await supports(method) else {
      throw SessionCommandError(
        "This action requires a newer Axod. Your Sessions and Workspace are unchanged.")
    }
  }
}
