import AxoProtocol
import Foundation

/// Pure local parse/encoding before a pending command hint is saved. Parameters
/// originate only from the closed operation-specific protocol DTOs.
struct AxodPiMutationRequest {
    let method: String
    let parameters: JSONValue

    init(target: PiChatTarget, commandID: UUID, operation: PiChatOperation,
         interactionID: UUID?, questionID: UUID?, optionID: UUID?, text: String?) throws {
        let data: Data
        let encoder = JSONEncoder()
        switch operation {
        case .sendMessage:
            method = AxoProtocol.Method.sendChatMessage
            guard let text, PiProtocolValidator.validMessageText(text) else { throw Self.invalid(method) }
            data = try encoder.encode(PiChatTextParameters(target: target, commandId: commandID, text: text))
        case .sendSteeringMessage:
            method = AxoProtocol.Method.sendChatSteeringMessage
            guard let interactionID, Self.nonzero(interactionID), let text,
                  PiProtocolValidator.validMessageText(text) else { throw Self.invalid(method) }
            data = try encoder.encode(PiChatSteeringParameters(target: target, commandId: commandID,
                                                             interactionId: interactionID, text: text))
        case .cancelTurn:
            method = AxoProtocol.Method.cancelChatTurn
            guard let interactionID, Self.nonzero(interactionID) else { throw Self.invalid(method) }
            data = try encoder.encode(PiChatCancelParameters(target: target, commandId: commandID, interactionId: interactionID))
        case .answerQuestion:
            method = AxoProtocol.Method.answerChatQuestion
            guard let interactionID, Self.nonzero(interactionID), let questionID, Self.nonzero(questionID),
                  let optionID, Self.nonzero(optionID) else { throw Self.invalid(method) }
            data = try encoder.encode(PiChatAnswerParameters(target: target, commandId: commandID,
                                                           interactionId: interactionID, questionId: questionID, optionId: optionID))
        case .setViewing:
            throw Self.invalid(AxoProtocol.Method.setChatViewing)
        }
        parameters = try JSONDecoder().decode(JSONValue.self, from: data)
        // The SDK independently creates a UUID hop ID at dispatch. This UUID is
        // only a fixed-width framing estimate, never a request/receipt identity.
        let frame = RPCRequest(id: .string(UUID().uuidString.lowercased()), method: method, params: parameters)
        guard try encoder.encode(frame).count <= AxoProtocolCodec.maximumFrameBytes else { throw Self.invalid(method) }
    }

    private static func nonzero(_ id: UUID) -> Bool {
        id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
    private static func invalid(_ method: String) -> AxoProtocolValidationError {
        .invalidParameters(method: method)
    }
}
