import AxoClient
import AxoProtocol
import Foundation

struct ForkConfirmation {
  private(set) var plan: SessionForkPlan?
  private(set) var request: SessionForkAttempt?
  private(set) var requiresFolder = false
  var selectedAgent: CodingAgent?

  init(retry: SessionForkAttempt? = nil) {
    request = retry
    requiresFolder = retry?.folder != nil
  }

  mutating func receive(_ plan: SessionForkPlan) {
    guard request == nil else { return }
    self.plan = plan
    selectedAgent = nil
  }

  func canSubmit(folder: String) -> Bool {
    if request != nil { return true }
    guard !requiresFolder || absolutePath(folder) != nil else { return false }
    switch plan?.decision {
    case .keep: return true
    case .choose(let agents): return selectedAgent.map(agents.contains) == true
    case .unavailable, nil: return false
    }
  }

  mutating func submit(folder: String) -> SessionForkAttempt? {
    if let request { return request }
    guard canSubmit(folder: folder) else { return nil }
    let agent: CodingAgent?
    if case .choose = plan?.decision { agent = selectedAgent } else { agent = nil }
    let submitted = SessionForkAttempt(folder: requiresFolder ? absolutePath(folder) : nil, agent: agent)
    request = submitted
    return submitted
  }

  mutating func rejectHarness() {
    request = nil
    plan = nil
    selectedAgent = nil
  }

  mutating func rejectFolder() {
    request = nil
    requiresFolder = true
  }

  // Validate against the destination's path syntax, not this device's.
  private func absolutePath(_ folder: String) -> String? {
    let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.utf8.contains(0),
      path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    else { return nil }
    return path
  }
}
