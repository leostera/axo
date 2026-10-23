import AppKit
import Foundation
import GhosttyKit
import UserNotifications

/// The Ghostty configuration that governs bells, notifications and command-finished alerts,
/// read with the same keys and defaults as the pinned Ghostty.app.
struct TerminalAttentionConfig: Equatable {
  struct BellFeatures: OptionSet, Equatable {
    let rawValue: UInt32
    static let system = BellFeatures(rawValue: 1 << 0)
    static let audio = BellFeatures(rawValue: 1 << 1)
    static let attention = BellFeatures(rawValue: 1 << 2)
    static let title = BellFeatures(rawValue: 1 << 3)
    static let border = BellFeatures(rawValue: 1 << 4)
    static let defaultValue: BellFeatures = [.attention, .title]
  }

  enum NotifyOnCommandFinish: String { case never, unfocused, always }

  struct CommandFinishActions: OptionSet, Equatable {
    let rawValue: UInt32
    static let bell = CommandFinishActions(rawValue: 1 << 0)
    static let notify = CommandFinishActions(rawValue: 1 << 1)
  }

  var bellFeatures = BellFeatures.defaultValue
  var desktopNotifications = true
  var notifyOnCommandFinish = NotifyOnCommandFinish.never
  var commandFinishActions = CommandFinishActions.bell
  var commandFinishAfter = Duration.seconds(5)

  init() {}

  init(config: ghostty_config_t) {
    var bell: UInt32 = 0
    if Self.get(config, "bell-features", &bell) { bellFeatures = BellFeatures(rawValue: bell) }
    var notifications = true
    if Self.get(config, "desktop-notifications", &notifications) {
      desktopNotifications = notifications
    }
    var mode: UnsafePointer<CChar>?
    if Self.get(config, "notify-on-command-finish", &mode), let mode {
      notifyOnCommandFinish = NotifyOnCommandFinish(rawValue: String(cString: mode)) ?? .never
    }
    var actions: UInt32 = 0
    if Self.get(config, "notify-on-command-finish-action", &actions) {
      commandFinishActions = CommandFinishActions(rawValue: actions)
    }
    var after: UInt = 0
    if Self.get(config, "notify-on-command-finish-after", &after) {
      commandFinishAfter = .milliseconds(Int64(after))
    }
  }

  private static func get<T>(_ config: ghostty_config_t, _ key: String, _ value: inout T) -> Bool {
    withUnsafeMutablePointer(to: &value) { ghostty_config_get(config, $0, key, UInt(key.utf8.count)) }
  }
}

/// Ghostty.app's decision rules for terminal attention signals, independent of AppKit effects.
enum TerminalAttentionPolicy {
  struct BellEffects: Equatable {
    var beep = false
    var requestAttention = false
  }

  static func bellEffects(_ features: TerminalAttentionConfig.BellFeatures) -> BellEffects {
    // `audio` (bell-audio-path), `title` and `border` are documented as unsupported in
    // docs/ghostty-surface-parity.md: titles are sidebar-owned and panes have no bell border.
    BellEffects(beep: features.contains(.system), requestAttention: features.contains(.attention))
  }

  struct CommandFinishedEffects: Equatable {
    var bell = false
    var notification: (title: String, body: String)?

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.bell == rhs.bell && lhs.notification?.title == rhs.notification?.title
        && lhs.notification?.body == rhs.notification?.body
    }
  }

  static func commandFinished(
    exitCode: Int16,
    durationNanoseconds: UInt64,
    surfaceFocused: Bool,
    config: TerminalAttentionConfig
  ) -> CommandFinishedEffects {
    switch config.notifyOnCommandFinish {
    case .never: return CommandFinishedEffects()
    case .unfocused where surfaceFocused: return CommandFinishedEffects()
    case .unfocused, .always: break
    }
    let duration = Duration.nanoseconds(Int64(clamping: durationNanoseconds))
    guard duration >= config.commandFinishAfter else { return CommandFinishedEffects() }

    var effects = CommandFinishedEffects(bell: config.commandFinishActions.contains(.bell))
    if config.commandFinishActions.contains(.notify) {
      let title =
        exitCode < 0 ? "Command Finished" : exitCode == 0 ? "Command Succeeded" : "Command Failed"
      let formatted = duration.formatted(
        .units(
          allowed: [.hours, .minutes, .seconds, .milliseconds], width: .abbreviated,
          fractionalPart: .hide))
      let body = exitCode < 0 ? "Command took \(formatted)." : "Command took \(formatted) and exited with code \(exitCode)."
      effects.notification = (title, body)
    }
    return effects
  }

  static func shouldPostDesktopNotification(config: TerminalAttentionConfig) -> Bool {
    config.desktopNotifications
  }
}

/// Delivers native macOS notifications. Authorization is requested lazily on first use, as in
/// Ghostty.app; denial silently drops notifications.
@MainActor
enum TerminalNotifications {
  static func post(title: String, body: String) {
    // Notification content comes from terminal output; never log it.
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
}
