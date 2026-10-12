import Foundation

public struct SessionCompletionParameters: Encodable, Sendable {
    public let target: WorkSessionTarget
    public let runtimes: [TerminalRuntime]
    public init(target: WorkSessionTarget, runtimes: [TerminalRuntime]) { self.target = target; self.runtimes = runtimes }
}
public struct SessionCompletionResult: Sendable {
    public let completed: [TerminalRuntime]
    public let retiredShellReceipts: [ShellPaneReceipt]
}
public extension AxoProtocolResultValidator {
    static func sessionCompletion(_ value: JSONValue, parameters: SessionCompletionParameters) throws -> SessionCompletionResult {
        let method = "axo.session.completion"
        guard case .object(let fields) = value, Set(fields.keys) == ["hostGeneration", "completed", "retiredShellReceipts"],
              case .string(let generation)? = fields["hostGeneration"], UUID(uuidString: generation) == parameters.target.hostGeneration,
              case .array(let completed)? = fields["completed"], completed.count <= 32,
              case .array(let retired)? = fields["retiredShellReceipts"], retired.count <= 32 else {
            throw AxoProtocolValidationError.invalidResult(method: method)
        }
        let expected = try parameters.runtimes.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        var proven: [TerminalRuntime] = []
        for item in completed {
            guard expected.contains(item) else { throw AxoProtocolValidationError.invalidResult(method: method) }
            let runtime = try JSONDecoder().decode(TerminalRuntime.self, from: JSONEncoder().encode(item))
            guard !proven.contains(runtime) else { throw AxoProtocolValidationError.invalidResult(method: method) }
            proven.append(runtime)
        }
        let source = MachineTarget(machineId: parameters.target.machineId, hostGeneration: parameters.target.hostGeneration)
        var receipts: [ShellPaneReceipt] = []
        for item in retired {
            let parsed = try JSONDecoder().decode(ShellPaneReceipt.self, from: JSONEncoder().encode(item))
            let wrapper: JSONValue = .object(["hostGeneration": .string(generation),
                "receipt": .object(["kind": .string("pane"), "receipt": item])])
            let result = try commandGet(wrapper, target: source)
            guard case .pane(let receipt)? = result.receipt, receipt.commandId == parsed.commandId, receipt.disposition == .removed,
                  case .remove(let target, let pane, let runtime) = receipt.intent,
                  target.machineId == parameters.target.machineId, target.workspaceId == parameters.target.workspaceId,
                  target.sessionId == parameters.target.sessionId, let runtime, proven.contains(runtime),
                  runtime.target.paneId == pane, !receipts.contains(receipt) else {
                throw AxoProtocolValidationError.invalidResult(method: method)
            }
            receipts.append(receipt)
        }
        return SessionCompletionResult(completed: proven, retiredShellReceipts: receipts)
    }
}
