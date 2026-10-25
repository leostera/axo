import AppKit
import GhosttyKit

/// C trampolines libghostty calls back into. Each hops onto the main actor: Axo enters libghostty
/// only from MainActor-bound surface calls and ticks, so callbacks arriving on another thread are
/// rejected rather than racing AppKit state.
extension GhosttyRuntime {
  /// `userdata` is the unretained runtime; the runtime outlives its `ghostty_app_t`.
  static func makeRuntimeConfig(userdata: UnsafeMutableRawPointer) -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
      userdata: userdata,
      supports_selection_clipboard: true,
      wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
      action_cb: { _, target, action in
        // Axo enters libghostty from MainActor-bound surface calls and ticks, so this callback
        // updates AppKit state synchronously on that same thread.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
          GhosttyRuntime.handleAction(target: target, action: action)
        }
      },
      read_clipboard_cb: { userdata, location, state, mimes, count, list in
        guard Thread.isMainThread else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        return MainActor.assumeIsolated {
          GhosttyRuntime.readClipboard(
            userdata: userdata,
            location: location,
            state: state,
            mimes: mimes,
            count: count,
            list: list
          )
        }
      },
      confirm_read_clipboard_cb: { userdata, confirm, state, request in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.confirmClipboardRead(
            userdata: userdata, confirm: confirm, state: state, request: request)
        }
      },
      write_clipboard_cb: { userdata, location, content, count, confirm in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
          GhosttyRuntime.writeClipboard(
            view: GhosttyRuntime.clipboardView(userdata),
            location: location, content: content, count: count, confirm: confirm)
        }
      },
      close_surface_cb: { userdata, _ in
        // With external I/O this means axod ended the output stream. Never free a surface
        // inside its own callback; handle it on the next main-queue turn.
        guard let view = GhosttyRuntime.clipboardView(userdata) else { return }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { view.runtime?.surfaces.outputEnded(view) }
        }
      }
    )
  }

  static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    let requested = ContinuousClock.now
    DispatchQueue.main.async {
      MainActor.assumeIsolated { runtime.tick(requestedAt: requested) }
    }
  }
}
