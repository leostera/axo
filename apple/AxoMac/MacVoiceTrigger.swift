import Foundation

enum MacVoiceTrigger: String, CaseIterable, Identifiable {
    case holdOption
    case doublePressOption

    static let settingsKey = "axoVoiceTrigger"
    static let defaultValue: Self = .holdOption
    static let doublePressInterval: TimeInterval = 0.4

    var id: Self { self }

    var title: String {
        switch self {
        case .holdOption: "Hold Option"
        case .doublePressOption: "Double-press Option to lock"
        }
    }

    var explanation: String {
        switch self {
        case .holdOption:
            "Hold either Option key to record; release it to stop and transcribe."
        case .doublePressOption:
            "Double-press either Option key to start or stop a locked recording. Releasing Option does not stop it."
        }
    }
}

enum MacVoiceGestureAction: Equatable {
    case beginHold
    case endHold
    case toggleLock
}

struct MacVoiceGestureResult: Equatable {
    let consumeEvent: Bool
    let action: MacVoiceGestureAction?

    static let passThrough = Self(consumeEvent: false, action: nil)
    static func consume(_ action: MacVoiceGestureAction? = nil) -> Self {
        Self(consumeEvent: true, action: action)
    }
}

struct MacVoiceOptionGesture {
    private struct Press {
        let trigger: MacVoiceTrigger
        let startedAt: Date
    }

    private var pressedKeys: [UInt16: Press] = [:]
    private var lastTapAt: Date?
    private var lastTapTrigger: MacVoiceTrigger?

    var isTrackingPress: Bool { !pressedKeys.isEmpty }

    mutating func handle(keyCode: UInt16, isDown: Bool, trigger: MacVoiceTrigger,
                         at time: Date) -> MacVoiceGestureResult {
        if isDown {
            guard pressedKeys.isEmpty else { return .passThrough }
            if lastTapTrigger != trigger {
                lastTapAt = nil
                lastTapTrigger = nil
            }
            pressedKeys[keyCode] = Press(trigger: trigger, startedAt: time)
            return trigger == .holdOption ? .consume(.beginHold) : .consume()
        }

        guard let press = pressedKeys.removeValue(forKey: keyCode) else { return .passThrough }
        switch press.trigger {
        case .holdOption:
            return .consume(.endHold)
        case .doublePressOption:
            let duration = time.timeIntervalSince(press.startedAt)
            guard duration >= 0, duration <= MacVoiceTrigger.doublePressInterval else {
                lastTapAt = nil
                lastTapTrigger = nil
                return .consume()
            }
            if let lastTapAt, time.timeIntervalSince(lastTapAt) <= MacVoiceTrigger.doublePressInterval {
                self.lastTapAt = nil
                lastTapTrigger = nil
                return .consume(.toggleLock)
            }
            lastTapAt = time
            lastTapTrigger = press.trigger
            return .consume()
        }
    }

    mutating func reset() {
        pressedKeys.removeAll()
        lastTapAt = nil
        lastTapTrigger = nil
    }
}
