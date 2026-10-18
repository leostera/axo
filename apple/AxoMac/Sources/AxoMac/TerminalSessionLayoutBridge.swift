import AxoRPC

private extension SessionSplitDirection {
  var terminalDirection: TerminalSplitDirection {
    switch self {
    case .right: .right
    case .down: .down
    }
  }
}

private extension TerminalSplitDirection {
  var sessionDirection: SessionSplitDirection {
    switch self {
    case .right: .right
    case .down: .down
    }
  }
}

extension TerminalLayout {
  init(_ sessionLayout: SessionLayout) {
    switch sessionLayout {
    case .pane(let shellID):
      self = .pane(shellID)
    case .split(let id, let direction, let ratio, let first, let second):
      self = .split(
        id: id,
        direction: direction.terminalDirection,
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
        direction: direction.sessionDirection,
        ratio: ratio,
        first: first.sessionLayout,
        second: second.sessionLayout
      )
    }
  }
}
