import AxoRPC

extension TerminalLayout {
  init(_ sessionLayout: SessionLayout) {
    switch sessionLayout {
    case .pane(let shellID):
      self = .pane(shellID)
    case .split(let id, let direction, let ratio, let first, let second):
      self = .split(
        id: id,
        direction: direction == .right ? .right : .down,
        ratio: ratio,
        first: TerminalLayout(first),
        second: TerminalLayout(second)
      )
    }
  }

  var sessionLayout: SessionLayout {
    switch self {
    case .pane(let shellID):
      .pane(shellID: shellID)
    case .split(let id, let direction, let ratio, let first, let second):
      .split(
        id: id,
        direction: direction == .right ? .right : .down,
        ratio: ratio,
        first: first.sessionLayout,
        second: second.sessionLayout
      )
    }
  }
}
