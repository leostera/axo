import AxoRPC
import Foundation

enum PendingTerminalSplitStatus: Equatable {
  case creating
  case rejected(String)
  case outcomeUnknown(String)
}

struct PendingTerminalSplit: Equatable, Identifiable {
  let id: UUID
  let sessionID: Int64
  let sessionUuid: String?
  let anchorShellID: Int64
  let direction: TerminalSplitDirection
  var ratio: Double
  var status: PendingTerminalSplitStatus
}

/// The persisted wire direction is the only split direction; no parallel app enum.
typealias TerminalSplitDirection = SessionSplitDirection

enum TerminalNavigationDirection: Int, Equatable {
  case previous = -1
  case next = 1
}

indirect enum TerminalLayout: Equatable, Identifiable {
  case pane(Int64)
  case split(
    id: UUID,
    direction: TerminalSplitDirection,
    ratio: Double,
    first: TerminalLayout,
    second: TerminalLayout
  )

  var id: String {
    switch self {
    case .pane(let shellID): "shell-\(shellID)"
    case .split(let id, _, _, _, _): "split-\(id.uuidString)"
    }
  }

  var shellIDs: Set<Int64> {
    switch self {
    case .pane(let shellID): [shellID]
    case .split(_, _, _, let first, let second): first.shellIDs.union(second.shellIDs)
    }
  }

  var orderedShellIDs: [Int64] {
    switch self {
    case .pane(let shellID): [shellID]
    case .split(_, _, _, let first, let second):
      first.orderedShellIDs + second.orderedShellIDs
    }
  }

  func adding(_ shellIDs: Set<Int64>) -> TerminalLayout {
    shellIDs.sorted().reduce(self) { layout, shellID in
      guard !layout.contains(shellID: shellID) else { return layout }
      return .split(
        id: UUID(),
        direction: .right,
        ratio: 0.5,
        first: layout,
        second: .pane(shellID)
      )
    }
  }

  var firstShellID: Int64? {
    switch self {
    case .pane(let shellID): shellID
    case .split(_, _, _, let first, _): first.firstShellID
    }
  }

  func contains(shellID: Int64) -> Bool {
    switch self {
    case .pane(let currentID): currentID == shellID
    case .split(_, _, _, let first, let second):
      first.contains(shellID: shellID) || second.contains(shellID: shellID)
    }
  }

  func inserting(
    shellID newShellID: Int64,
    direction: TerminalSplitDirection,
    beside targetShellID: Int64,
    ratio: Double = 0.5
  ) -> TerminalLayout? {
    switch self {
    case .pane(let currentID) where currentID == targetShellID:
      return .split(
        id: UUID(),
        direction: direction,
        ratio: min(max(ratio, 0.01), 0.99),
        first: self,
        second: .pane(newShellID)
      )
    case .pane:
      return nil
    case .split(let id, let existingDirection, let existingRatio, let first, let second):
      if let updatedFirst = first.inserting(
        shellID: newShellID,
        direction: direction,
        beside: targetShellID,
        ratio: ratio
      ) {
        return .split(
          id: id,
          direction: existingDirection,
          ratio: existingRatio,
          first: updatedFirst,
          second: second
        )
      }
      if let updatedSecond = second.inserting(
        shellID: newShellID,
        direction: direction,
        beside: targetShellID,
        ratio: ratio
      ) {
        return .split(
          id: id,
          direction: existingDirection,
          ratio: existingRatio,
          first: first,
          second: updatedSecond
        )
      }
      return nil
    }
  }

  func placing(
    shellID: Int64,
    direction: TerminalSplitDirection,
    beside anchorShellID: Int64,
    ratio: Double
  ) -> TerminalLayout {
    let base = contains(shellID: shellID) ? removing(shellID: shellID) : self
    guard let base, !base.contains(shellID: shellID) else { return .pane(shellID) }
    return base.inserting(
      shellID: shellID,
      direction: direction,
      beside: anchorShellID,
      ratio: ratio
    ) ?? base.adding([shellID])
  }

  func focusTargetAfterClosing(
    _ shellID: Int64,
    remainingShellIDs: Set<Int64>
  ) -> Int64? {
    let orderedIDs = orderedShellIDs
    guard let index = orderedIDs.firstIndex(of: shellID) else { return nil }

    let candidates: [Int64]
    if index == 0 {
      candidates = Array(orderedIDs.dropFirst())
    } else {
      candidates = Array(orderedIDs[..<index].reversed())
        + Array(orderedIDs.dropFirst(index + 1))
    }
    return candidates.first(where: remainingShellIDs.contains)
  }

  func removing(shellID: Int64) -> TerminalLayout? {
    switch self {
    case .pane(let currentID):
      return currentID == shellID ? nil : self
    case .split(let id, let direction, let ratio, let first, let second):
      let remainingFirst = first.removing(shellID: shellID)
      let remainingSecond = second.removing(shellID: shellID)
      switch (remainingFirst, remainingSecond) {
      case (nil, nil):
        return nil
      case (let remaining?, nil):
        return remaining
      case (nil, let remaining?):
        return remaining
      case (let remainingFirst?, let remainingSecond?):
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }

  func pruned(to openShellIDs: Set<Int64>) -> TerminalLayout? {
    switch self {
    case .pane(let shellID):
      return openShellIDs.contains(shellID) ? self : nil
    case .split(let id, let direction, let ratio, let first, let second):
      let remainingFirst = first.pruned(to: openShellIDs)
      let remainingSecond = second.pruned(to: openShellIDs)
      switch (remainingFirst, remainingSecond) {
      case (nil, nil):
        return nil
      case (let remaining?, nil):
        return remaining
      case (nil, let remaining?):
        return remaining
      case (let remainingFirst?, let remainingSecond?):
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          first: remainingFirst,
          second: remainingSecond
        )
      }
    }
  }

  // Ratios are excluded so divider drags don't replace terminal pane views.
  var structuralIdentity: StructuralIdentity {
    StructuralIdentity(self)
  }

  func resizing(splitID: UUID, to newRatio: Double) -> TerminalLayout? {
    switch self {
    case .pane:
      return nil
    case .split(let id, let direction, let ratio, let first, let second):
      if id == splitID {
        return .split(
          id: id, direction: direction, ratio: newRatio, first: first, second: second
        )
      }
      if let updatedFirst = first.resizing(splitID: splitID, to: newRatio) {
        return .split(
          id: id, direction: direction, ratio: ratio, first: updatedFirst, second: second
        )
      }
      if let updatedSecond = second.resizing(splitID: splitID, to: newRatio) {
        return .split(
          id: id, direction: direction, ratio: ratio, first: first, second: updatedSecond
        )
      }
      return nil
    }
  }

  struct StructuralIdentity: Hashable {
    private let representation: Representation

    init(_ layout: TerminalLayout) {
      switch layout {
      case .pane(let shellID):
        representation = .pane(shellID)
      case .split(_, let direction, _, let first, let second):
        representation = .split(direction, first.structuralIdentity, second.structuralIdentity)
      }
    }

    private indirect enum Representation: Hashable {
      case pane(Int64)
      case split(TerminalSplitDirection, StructuralIdentity, StructuralIdentity)
    }
  }
}

indirect enum TerminalLayoutPresentation: Equatable {
  case pane(Int64)
  case pending(PendingTerminalSplit)
  case split(
    id: UUID,
    direction: TerminalSplitDirection,
    ratio: Double,
    isPending: Bool,
    first: TerminalLayoutPresentation,
    second: TerminalLayoutPresentation
  )

  init(_ layout: TerminalLayout) {
    switch layout {
    case .pane(let shellID):
      self = .pane(shellID)
    case .split(let id, let direction, let ratio, let first, let second):
      self = .split(
        id: id,
        direction: direction,
        ratio: ratio,
        isPending: false,
        first: TerminalLayoutPresentation(first),
        second: TerminalLayoutPresentation(second)
      )
    }
  }

  func inserting(_ pending: PendingTerminalSplit) -> TerminalLayoutPresentation? {
    switch self {
    case .pane(let shellID) where shellID == pending.anchorShellID:
      return .split(
        id: pending.id,
        direction: pending.direction,
        ratio: pending.ratio,
        isPending: true,
        first: self,
        second: .pending(pending)
      )
    case .pane, .pending:
      return nil
    case .split(let id, let direction, let ratio, let isPending, let first, let second):
      if let updatedFirst = first.inserting(pending) {
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          isPending: isPending,
          first: updatedFirst,
          second: second
        )
      }
      if let updatedSecond = second.inserting(pending) {
        return .split(
          id: id,
          direction: direction,
          ratio: ratio,
          isPending: isPending,
          first: first,
          second: updatedSecond
        )
      }
      return nil
    }
  }

  var structuralIdentity: StructuralIdentity {
    StructuralIdentity(self)
  }

  struct StructuralIdentity: Hashable {
    private let representation: Representation

    init(_ layout: TerminalLayoutPresentation) {
      switch layout {
      case .pane(let shellID):
        representation = .pane(shellID)
      case .pending(let split):
        representation = .pending(split.id)
      case .split(_, let direction, _, _, let first, let second):
        representation = .split(direction, first.structuralIdentity, second.structuralIdentity)
      }
    }

    private indirect enum Representation: Hashable {
      case pane(Int64)
      case pending(UUID)
      case split(TerminalSplitDirection, StructuralIdentity, StructuralIdentity)
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
        direction: direction,
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
        direction: direction,
        ratio: ratio,
        first: first.sessionLayout,
        second: second.sessionLayout
      )
    }
  }
}
