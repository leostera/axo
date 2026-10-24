import AppKit
import GhosttyKit
import UserNotifications

/// Dispatches libghostty `action_cb` events to the target surface or application.
extension GhosttyRuntime {
  static func handleAction(
    target: ghostty_target_s,
    action: ghostty_action_s
  ) -> Bool {
    if action.tag == GHOSTTY_ACTION_OPEN_URL {
      let openURL = action.action.open_url
      guard let value = TerminalLinkPolicy.string(openURL.url, length: Int(openURL.len)) else {
        return true
      }
      return TerminalLinkPolicy.open(kind: TerminalLinkKind(openURL.kind), value: value)
    }
    guard target.tag == GHOSTTY_TARGET_SURFACE,
      let surface = target.target.surface,
      let userdata = ghostty_surface_userdata(surface)
    else { return false }
    let view = Unmanaged<GhosttySurfaceNSView>.fromOpaque(userdata).takeUnretainedValue()
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      view.setCursorShape(action.action.mouse_shape)
      return true
    case GHOSTTY_ACTION_SCROLLBAR:
      let scrollbar = action.action.scrollbar
      view.updateScrollbar(
        TerminalScrollbarState(
          total: scrollbar.total, offset: scrollbar.offset, length: scrollbar.len))
      return true
    case GHOSTTY_ACTION_CELL_SIZE:
      view.cellSizeDidChange()
      return true
    case GHOSTTY_ACTION_RING_BELL:
      view.runtime?.ringBell(for: view)
      return true
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
      guard let runtime = view.runtime,
        TerminalAttentionPolicy.shouldPostDesktopNotification(config: runtime.attentionConfig)
      else { return true }
      let note = action.action.desktop_notification
      TerminalNotifications.post(
        title: note.title.map { String(cString: $0) } ?? "",
        body: note.body.map { String(cString: $0) } ?? "")
      return true
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      guard let runtime = view.runtime else { return true }
      let finished = action.action.command_finished
      let effects = TerminalAttentionPolicy.commandFinished(
        exitCode: finished.exit_code, durationNanoseconds: finished.duration,
        surfaceFocused: view.isFocusedTerminal, config: runtime.attentionConfig)
      if effects.bell { runtime.ringBell(for: view) }
      if let note = effects.notification { TerminalNotifications.post(title: note.title, body: note.body) }
      return true
    case GHOSTTY_ACTION_SECURE_INPUT:
      let mode = action.action.secure_input
      view.apply(.secureInput(mode == GHOSTTY_SECURE_INPUT_ON ? .on : mode == GHOSTTY_SECURE_INPUT_OFF ? .off : .toggle))
      view.runtime?.refreshSecureInput()
      return true
    case GHOSTTY_ACTION_READONLY:
      view.apply(.readonly(action.action.readonly == GHOSTTY_READONLY_ON))
      return true
    case GHOSTTY_ACTION_RENDERER_HEALTH:
      view.apply(.rendererHealthy(action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY))
      return true
    case GHOSTTY_ACTION_KEY_SEQUENCE:
      view.apply(.keySequence(active: action.action.key_sequence.active))
      return true
    case GHOSTTY_ACTION_KEY_TABLE:
      let table = action.action.key_table
      switch table.tag {
      case GHOSTTY_KEY_TABLE_ACTIVATE:
        let name = TerminalLinkPolicy.string(table.value.activate.name, length: Int(table.value.activate.len)) ?? ""
        view.apply(.keyTableActivate(name))
      case GHOSTTY_KEY_TABLE_DEACTIVATE: view.apply(.keyTableDeactivate)
      default: view.apply(.keyTableDeactivateAll)
      }
      return true
    case GHOSTTY_ACTION_PROGRESS_REPORT:
      let report = action.action.progress_report
      let state: TerminalSurfaceStatus.Event.ProgressState
      switch report.state {
      case GHOSTTY_PROGRESS_STATE_REMOVE: state = .remove
      case GHOSTTY_PROGRESS_STATE_SET: state = .set
      case GHOSTTY_PROGRESS_STATE_ERROR: state = .error
      case GHOSTTY_PROGRESS_STATE_PAUSE: state = .pause
      default: state = .indeterminate
      }
      view.apply(.progress(state, percent: report.progress))
      return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      let exited = action.action.child_exited
      view.apply(.childExited(.init(exitCode: exited.exit_code, runtimeMilliseconds: exited.timetime_ms)))
      return true
    case GHOSTTY_ACTION_SET_TITLE:
      view.apply(.title(action.action.set_title.title.map { String(cString: $0) }))
      return true
    case GHOSTTY_ACTION_PWD:
      view.apply(.pwd(action.action.pwd.pwd.map { String(cString: $0) }))
      return true
    case GHOSTTY_ACTION_START_SEARCH:
      view.apply(.startSearch(action.action.start_search.needle.map { String(cString: $0) } ?? ""))
      return true
    case GHOSTTY_ACTION_END_SEARCH:
      view.apply(.endSearch)
      return true
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      view.apply(.searchTotal(Int(action.action.search_total.total)))
      return true
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      view.apply(.searchSelected(Int(action.action.search_selected.selected)))
      return true
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
      let link = action.action.mouse_over_link
      view.updateHoveredLink(TerminalLinkPolicy.string(link.url, length: Int(link.len)))
      return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      switch action.action.mouse_visibility {
      case GHOSTTY_MOUSE_VISIBLE:
        view.setCursorVisibility(true)
        return true
      case GHOSTTY_MOUSE_HIDDEN:
        view.setCursorVisibility(false)
        return true
      default:
        return false
      }
    default:
      return false
    }
  }
}
