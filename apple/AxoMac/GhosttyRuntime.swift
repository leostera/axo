import AppKit
import GhosttyKit

final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?

    init() throws {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0, let config = ghostty_config_new() else { throw LaunchError.ghosttyInitialization }
        defer { ghostty_config_free(config) }
        ghostty_config_finalize(config)
        var callbacks = ghostty_runtime_config_s()
        callbacks.userdata = Unmanaged.passUnretained(self).toOpaque()
        callbacks.wakeup_cb = { pointer in
            guard let pointer else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { if let app = runtime.app { ghostty_app_tick(app) } }
        }
        callbacks.action_cb = { _, _, _ in false }
        // Clipboard reads are denied in the prototype. Explicit Cmd-V pastes via surface_text.
        callbacks.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        callbacks.confirm_read_clipboard_cb = { pointer, _, state, _ in
            guard let pointer else { return }
            let view = Unmanaged<TerminalView>.fromOpaque(pointer).takeUnretainedValue()
            if let surface = view.surface { ghostty_surface_deny_clipboard_request(surface, state) }
        }
        callbacks.write_clipboard_cb = { _, _, _, _, _ in }
        callbacks.close_surface_cb = { _, _ in }
        guard let app = ghostty_app_new(&callbacks, config) else { throw LaunchError.ghosttyInitialization }
        self.app = app
    }

    func setFocus(_ focused: Bool) { if let app { ghostty_app_set_focus(app, focused) } }
    deinit { if let app { ghostty_app_free(app) } }
}
