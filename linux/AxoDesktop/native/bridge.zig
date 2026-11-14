//! Private prototype ABI. GTK calls, widget ownership and teardown stay on the main thread.
const std = @import("std");
const global = @import("global.zig");
const apprt = @import("apprt.zig");
const CoreApp = @import("App.zig");
const Config = @import("config.zig").Config;
const gtk = @import("gtk");
const Surface = apprt.gtk.class.Surface;
const main = @import("main_ghostty.zig");
pub const std_options = main.std_options;

const Engine = struct { core: *CoreApp, runtime: apprt.App, widgets: usize };
extern fn g_object_weak_ref(
    object: *anyopaque,
    notify: *const fn (?*anyopaque, *anyopaque) callconv(.c) void,
    data: ?*anyopaque,
) void;

fn surfaceReleased(context: ?*anyopaque, _: *anyopaque) callconv(.c) void {
    const engine: *Engine = @ptrCast(@alignCast(context.?));
    std.debug.assert(engine.widgets > 0);
    engine.widgets -= 1;
}
var initialized = false;
var arguments = [_][*:0]u8{
    @constCast("axo-desktop"),
    @constCast("--config-default-files=false"),
    @constCast("--keybind=clear"),
    @constCast("--keybind=ctrl+shift+c=copy_to_clipboard"),
    @constCast("--keybind=ctrl+shift+v=paste_from_clipboard"),
    @constCast("--class=dev.leostera.AxoDesktop.Prototype"),
    @constCast("--gtk-single-instance=false"),
    @constCast("--shell-integration=none"),
    @constCast("--font-size=14"),
    @constCast("--background=10141e"),
    @constCast("--foreground=e6edf3"),
    @constCast("--palette=2=#40e080"),
};

pub export fn axo_gtk_engine_new() ?*Engine {
    if (initialized) return null;
    initialized = true;
    const environment: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..length: {
        var n: usize = 0;
        while (std.c.environ[n]) |_| : (n += 1) {}
        break :length n;
    } :null] } };
    global.init(.{ .c = .{ .argc = arguments.len, .argv = &arguments, .environ = environment } }) catch return null;
    return createEngine() catch return null;
}

fn createEngine() !*Engine {
    const alloc = global.alloc();
    const engine = try alloc.create(Engine);
    errdefer alloc.destroy(engine);
    engine.core = try CoreApp.create(alloc);
    errdefer engine.core.destroy();
    engine.widgets = 0;
    // Config.load reads/creates default files before CLI overrides. Start with
    // defaults and our fixed arguments instead; never read/write Ghostty settings.
    var config = try Config.default(alloc);
    defer config.deinit();
    try config.loadCliArgs(alloc);
    try config.finalize();
    engine.runtime = .{ .app = try apprt.gtk.class.Application.newWithConfig(
        &engine.runtime,
        engine.core,
        &config,
    ) };
    return engine;
}

/// Borrowed application; Rust takes its own GObject reference before retaining it.
pub export fn axo_gtk_application(engine: *Engine) *gtk.Application {
    return engine.runtime.app.as(gtk.Application);
}

/// Floating widget; the caller must sink its GObject reference and parent it.
pub export fn axo_gtk_surface_new(engine: *Engine, command: ?[*:0]const u8) ?*gtk.Widget {
    var overrides: @import("apprt/gtk/class/Overrides.zig") = .none;
    if (command) |value| overrides.command = .{ .shell = std.mem.span(value) };
    const surface = Surface.new(overrides);
    // CoreApp only counts realized surfaces. Track the GObject from creation too.
    engine.widgets += 1;
    g_object_weak_ref(surface, surfaceReleased, engine);
    surface.setConfig(engine.runtime.app.getConfig());
    surface.as(gtk.Widget).setHexpand(1);
    surface.as(gtk.Widget).setVexpand(1);
    return surface.as(gtk.Widget);
}

pub export fn axo_gtk_surface_focus(surface: *Surface) void {
    surface.grabFocus();
}

pub export fn axo_gtk_run(engine: *Engine) c_int {
    engine.runtime.run() catch return -1;
    return 0;
}

pub export fn axo_gtk_request_quit(engine: *Engine) void {
    engine.runtime.app.quit();
}

pub const SurfaceStats = extern struct { ready: u32, columns: u32, rows: u32, width: u32, height: u32 };

pub export fn axo_gtk_surface_stats(widget: *Surface, out: *SurfaceStats) void {
    out.* = .{ .ready = 0, .columns = 0, .rows = 0, .width = 0, .height = 0 };
    if (widget.core()) |core| {
        const grid = core.size.grid();
        const screen = core.size.screen;
        out.* = .{ .ready = 1, .columns = grid.columns, .rows = grid.rows, .width = screen.width, .height = screen.height };
    }
}

/// The host must first destroy/unref its widgets and disconnect callbacks. Refuse
/// rather than freeing an allocator while an outstanding surface can still use it.
pub export fn axo_gtk_engine_free(engine: *Engine) c_int {
    if (engine.widgets != 0 or engine.core.surfaces.items.len != 0) return -1;
    const alloc = global.alloc();
    engine.runtime.terminate();
    engine.core.destroy();
    alloc.destroy(engine);
    global.deinit();
    return 0;
}
