/// axod's JSON-RPC method names: the only place they are spelled. Capability checks against
/// `axo.protocol.negotiate`'s method list use these too.
public enum AxodMethodName: String, CaseIterable, Sendable {
  case negotiate = "axo.protocol.negotiate"
  case health = "axo.daemon.health"
  case relayStatus = "axo.relay.status"
  case relayConnect = "axo.relay.connect"
  case relayLink = "axo.relay.link"
  case configGet = "axo.config.get"
  case configSet = "axo.config.set"
  case sessionList = "axo.session.list"
  case sessionCreate = "axo.session.create"
  case sessionClose = "axo.session.close"
  case sessionReopen = "axo.session.reopen"
  case sessionRename = "axo.session.rename"
  case sessionLayoutSet = "axo.session.layout.set"
  case piRestartForce = "axo.session.pi.restart.force.v2"
  case piRestartAuto = "axo.session.pi.restart.auto.v1"
  case shellCreate = "axo.shell.create"
  case shellClose = "axo.shell.close"
  case shellBusy = "axo.shell.busy"
  case clientViewportSet = "axo.client.viewport.set"
  /// Other Macs' Sessions, opened here in a pane (RFD0024).
  case peerSessionsList = "axo.peer.sessions.list"
  case peerSessionOpen = "axo.peer.session.open"
  case peerSessionClose = "axo.peer.session.close"
  /// What agents and tools ask the person (RFD0029). Only Axo.app answers on this Mac.
  case elicitationList = "axo.elicitation.list"
  case elicitationResolve = "axo.elicitation.resolve"
}
