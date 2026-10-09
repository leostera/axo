import AppKit
import Foundation

struct MacVoiceKeyBinding: Equatable, RawRepresentable {
    enum ModifierKey: String, CaseIterable, Identifiable {
        case rightOption = "option"
        case control, command, shift, function

        var id: Self { self }
        var title: String {
            switch self {
            case .rightOption: "Right Option"
            case .control: "Control"
            case .command: "Command"
            case .shift: "Shift"
            case .function: "Fn"
            }
        }
        var keyCodes: Set<UInt16> {
            switch self {
            case .rightOption: [61]
            case .control: [59, 62]
            case .command: [54, 55]
            case .shift: [56, 60]
            case .function: [63]
            }
        }
        var modifierFlag: NSEvent.ModifierFlags {
            switch self {
            case .rightOption: .option
            case .control: .control
            case .command: .command
            case .shift: .shift
            case .function: .function
            }
        }

        init?(keyCode: UInt16) {
            guard let key = Self.allCases.first(where: { $0.keyCodes.contains(keyCode) }) else { return nil }
            self = key
        }
    }

    enum Input: Equatable {
        case modifier(ModifierKey)
        case key(keyCode: UInt16, modifiers: UInt, name: String)
    }

    static let settingsKey = "axoVoiceKeyBinding"
    static let defaultValue = Self(input: .modifier(.rightOption))
    static let gestureInterval: TimeInterval = 0.4
    static let relevantModifierFlags: NSEvent.ModifierFlags = [.option, .control, .command, .shift, .function]

    let input: Input
    private init(input: Input) { self.input = input }

    var rawValue: String {
        switch input {
        case .modifier(let key): "modifier:\(key.rawValue)"
        case .key(let keyCode, let modifiers, let name):
            "key:\(keyCode):\(modifiers):\(Data(name.utf8).base64EncodedString())"
        }
    }

    init?(rawValue: String) {
        let fields = rawValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        if fields.count == 2, fields[0] == "modifier", let key = ModifierKey(rawValue: String(fields[1])) {
            self.init(input: .modifier(key)); return
        }
        guard fields.count == 4, fields[0] == "key",
              let keyCode = UInt16(fields[1]), keyCode < 128,
              let modifiers = UInt(fields[2]),
              NSEvent.ModifierFlags(rawValue: modifiers).subtracting(Self.relevantModifierFlags).isEmpty,
              let nameData = Data(base64Encoded: String(fields[3])),
              let name = String(data: nameData, encoding: .utf8),
              !name.isEmpty, name.utf8.count <= 32 else { return nil }
        self.init(input: .key(keyCode: keyCode, modifiers: modifiers, name: name))
    }

    var title: String {
        return switch input {
        case .modifier(let key): key.title
        case .key(_, let rawModifiers, let name): Self.keyTitle(modifiers: rawModifiers, name: name)
        }
    }

    private static func keyTitle(modifiers rawModifiers: UInt, name: String) -> String {
        let modifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
        let prefix = [
            (NSEvent.ModifierFlags.control, "⌃"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.command, "⌘"),
            (.function, "fn "),
        ].filter { modifiers.contains($0.0) }.map(\.1).joined()
        return "\(prefix)\(name)"
    }

    var isModifierKey: Bool {
        if case .modifier = input { return true }
        return false
    }

    func matches(keyCode: UInt16) -> Bool {
        return switch input {
        case .modifier(let key): key.keyCodes.contains(keyCode)
        case .key(let boundKeyCode, _, _): boundKeyCode == keyCode
        }
    }

    func matchesModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        let active = flags.intersection(Self.relevantModifierFlags)
        return switch input {
        case .modifier(let key): active == key.modifierFlag
        case .key(_, let modifiers, _): active.rawValue == modifiers
        }
    }

    static func capture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, name: String) -> Self? {
        if keyCode == 58 { return nil } // Left Option is intentionally not a voice trigger.
        if let modifier = ModifierKey(keyCode: keyCode) { return Self(input: .modifier(modifier)) }
        let cleanName = name.trimmingCharacters(in: .controlCharacters)
        guard keyCode < 128, !cleanName.isEmpty, cleanName.utf8.count <= 32 else { return nil }
        let relevant = modifiers.intersection(relevantModifierFlags)
        return Self(input: .key(keyCode: keyCode, modifiers: relevant.rawValue, name: cleanName))
    }
}

enum MacVoiceGestureAction: Equatable {
    case beginHold
    case endHold
    case lockRecording
    case unlockRecording
}

struct MacVoiceGestureResult: Equatable {
    let consumeEvent: Bool
    let actions: [MacVoiceGestureAction]

    static let passThrough = Self(consumeEvent: false, actions: [])
    static func consume(_ actions: MacVoiceGestureAction...) -> Self {
        Self(consumeEvent: true, actions: actions)
    }
}

/// Resolves tap-vs-hold timing so both push-to-talk and double-tap lock/unlock work on one key.
struct MacVoiceKeyGesture {
    private enum Phase {
        case idle
        case pushToTalk(keyCode: UInt16, startedAt: Date)
        case awaitingLock(deadline: Date)
        case lockingPress(keyCode: UInt16, startedAt: Date)
        case locked
        case unlockingPress(keyCode: UInt16, startedAt: Date)
        case awaitingUnlock(deadline: Date)
        case unlockingSecondPress(keyCode: UInt16, startedAt: Date)
    }

    private var phase: Phase = .idle

    var timeoutDeadline: Date? {
        switch phase {
        case .awaitingLock(let deadline), .awaitingUnlock(let deadline): deadline
        default: nil
        }
    }

    func isTracking(keyCode: UInt16) -> Bool {
        switch phase {
        case .pushToTalk(let tracked, _), .lockingPress(let tracked, _),
             .unlockingPress(let tracked, _), .unlockingSecondPress(let tracked, _): tracked == keyCode
        default: false
        }
    }

    mutating func handle(keyCode: UInt16, isDown: Bool, at time: Date) -> MacVoiceGestureResult {
        if isDown { return keyDown(keyCode: keyCode, at: time) }
        return keyUp(keyCode: keyCode, at: time)
    }

    mutating func expire(at time: Date) -> MacVoiceGestureResult {
        guard let deadline = timeoutDeadline, time >= deadline else { return .passThrough }
        switch phase {
        case .awaitingLock:
            phase = .idle
            return .consume(.endHold)
        case .awaitingUnlock:
            phase = .locked
            return .consume()
        default:
            return .passThrough
        }
    }

    mutating func clear() { phase = .idle }

    mutating func reset() -> MacVoiceGestureResult {
        switch phase {
        case .locked, .unlockingPress, .awaitingUnlock, .unlockingSecondPress:
            phase = .locked
            return .consume()
        case .pushToTalk, .awaitingLock, .lockingPress:
            phase = .idle
            return .consume(.endHold)
        case .idle:
            return .passThrough
        }
    }

    private mutating func keyDown(keyCode: UInt16, at time: Date) -> MacVoiceGestureResult {
        switch phase {
        case .idle:
            phase = .pushToTalk(keyCode: keyCode, startedAt: time)
            return .consume(.beginHold)
        case .awaitingLock(let deadline) where time <= deadline:
            phase = .lockingPress(keyCode: keyCode, startedAt: time)
            return .consume()
        case .awaitingLock:
            phase = .pushToTalk(keyCode: keyCode, startedAt: time)
            return .consume(.endHold, .beginHold)
        case .locked:
            phase = .unlockingPress(keyCode: keyCode, startedAt: time)
            return .consume()
        case .awaitingUnlock(let deadline) where time <= deadline:
            phase = .unlockingSecondPress(keyCode: keyCode, startedAt: time)
            return .consume()
        case .awaitingUnlock:
            phase = .unlockingPress(keyCode: keyCode, startedAt: time)
            return .consume()
        case .pushToTalk, .lockingPress, .unlockingPress, .unlockingSecondPress:
            return .consume()
        }
    }

    private mutating func keyUp(keyCode: UInt16, at time: Date) -> MacVoiceGestureResult {
        switch phase {
        case .pushToTalk(let tracked, let startedAt) where tracked == keyCode:
            guard time.timeIntervalSince(startedAt) <= MacVoiceKeyBinding.gestureInterval else {
                phase = .idle
                return .consume(.endHold)
            }
            phase = .awaitingLock(deadline: time.addingTimeInterval(MacVoiceKeyBinding.gestureInterval))
            return .consume()
        case .lockingPress(let tracked, let startedAt) where tracked == keyCode:
            if time.timeIntervalSince(startedAt) <= MacVoiceKeyBinding.gestureInterval {
                phase = .locked
                return .consume(.lockRecording)
            }
            phase = .idle
            return .consume(.endHold)
        case .unlockingPress(let tracked, let startedAt) where tracked == keyCode:
            if time.timeIntervalSince(startedAt) <= MacVoiceKeyBinding.gestureInterval {
                phase = .awaitingUnlock(deadline: time.addingTimeInterval(MacVoiceKeyBinding.gestureInterval))
            } else {
                phase = .locked
            }
            return .consume()
        case .unlockingSecondPress(let tracked, let startedAt) where tracked == keyCode:
            if time.timeIntervalSince(startedAt) <= MacVoiceKeyBinding.gestureInterval {
                phase = .idle
                return .consume(.unlockRecording)
            }
            phase = .locked
            return .consume()
        default:
            return .passThrough
        }
    }
}
