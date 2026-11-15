//! Native Rust/GTK4 shell around Ghostty's actual GTK terminal widget.
mod attachment;
mod catalog_task;
mod ghostty;
#[cfg(test)]
mod options_tests;
mod settings;
mod style;
mod task;
mod tray;
mod workbench;

use clap::Parser;
use ghostty::{Engine, Surface, SurfaceStats};
use gtk4::{glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
    rc::Rc,
};

#[derive(Clone, Parser)]
#[command(
    name = "AxoDesktop",
    about = "GTK4/Ghostty prototype: local Session workbench or explicit terminal"
)]
struct Options {
    /// Local command in standalone mode; never used as an attachment fallback.
    #[arg(long, conflicts_with_all = ["attach_socket", "shell", "socket"])]
    command: Option<String>,
    /// Explicit axod RPC socket for the local Session workbench; never starts/upgrades axod.
    #[arg(long, conflicts_with_all = ["command", "attach_socket", "shell"])]
    socket: Option<PathBuf>,
    /// Explicit snapshot-v3 daemon attach.sock; no implicit paired-host connection.
    #[arg(long, requires = "shell")]
    attach_socket: Option<PathBuf>,
    /// Existing daemon-owned shell ID.
    #[arg(long, requires = "attach_socket", value_parser = clap::value_parser!(i64).range(1..))]
    shell: Option<i64>,
    /// Development-only renderer readback of this window, refreshed while mapped.
    #[arg(long)]
    snapshot: Option<PathBuf>,
    /// Development-only JSON with the native terminal's current grid/pixel dimensions.
    #[arg(long)]
    diagnostics: Option<PathBuf>,
}

#[derive(Clone)]
enum TerminalSource {
    Standalone(Option<String>),
    Attached { socket: PathBuf, shell: i64 },
}

#[derive(Clone)]
enum WindowSource {
    Terminal(TerminalSource),
    Workbench { socket: PathBuf },
}

impl Options {
    fn source(&self) -> Result<WindowSource, String> {
        match (&self.socket, &self.attach_socket, self.shell, &self.command) {
            (Some(socket), None, None, None) => Ok(WindowSource::Workbench { socket: socket.clone() }),
            (None, Some(socket), Some(shell), None) if shell > 0 => Ok(WindowSource::Terminal(TerminalSource::Attached {
                socket: socket.clone(),
                shell,
            })),
            (None, None, None, command) => Ok(WindowSource::Terminal(TerminalSource::Standalone(command.clone()))),
            _ => Err(
                "choose --socket for the workbench, --attach-socket with a positive --shell, or standalone --command"
                    .into(),
            ),
        }
    }
}

fn main() -> std::process::ExitCode {
    match run(Options::parse()) {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("AxoDesktop: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn run(options: Options) -> Result<(), String> {
    let source = options.source()?;
    let engine = Rc::new(Engine::new()?);
    // Native Ghostty initializes GTK first; this also establishes gtk-rs's main-thread guard.
    gtk4::init().map_err(|error| error.to_string())?;
    style::install()?;
    let app = engine.application();
    let failure = Rc::new(RefCell::new(None));
    let activated = app.connect_activate({
        let engine = engine.clone();
        let failure = failure.clone();
        move |app| {
            // Rust owns the window. Suppress Ghostty's default "new Ghostty window" handler.
            app.stop_signal_emission_by_name("activate");
            let created = match &source {
                WindowSource::Terminal(source) => create_window(app, &engine, &options, source),
                WindowSource::Workbench { socket } => {
                    workbench::create_window(app, &engine, &options, socket)
                }
            };
            if let Err(error) = created {
                *failure.borrow_mut() = Some(error);
                // activate runs before Ghostty marks its run loop live.
                let engine = engine.clone();
                glib::idle_add_local_once(move || engine.request_quit());
            }
        }
    });
    let result = engine.run();
    // Ghostty's quit handler destroys GhosttyWindow instances only. These are Rust windows.
    for window in app.windows() {
        window.destroy();
    }
    app.disconnect(activated);
    let context = glib::MainContext::default();
    while context.pending() {
        context.iteration(false);
    }
    drop(app);
    let mut engine =
        Rc::try_unwrap(engine).map_err(|_| "a GTK callback retained the engine after shutdown")?;
    engine.finish()?;
    result?;
    if let Some(error) = failure.borrow_mut().take() {
        return Err(error);
    }
    eprintln!("AxoDesktop: clean shutdown; terminal widgets released");
    Ok(())
}

fn create_window(
    app: &gtk4::Application,
    engine: &Rc<Engine>,
    options: &Options,
    source: &TerminalSource,
) -> Result<(), String> {
    let window = gtk4::ApplicationWindow::builder()
        .application(app)
        .title("AxoDesktop · GTK4 prototype")
        .default_width(960)
        .default_height(640)
        .build();
    let header = gtk4::HeaderBar::new();
    let title = gtk4::Label::new(Some("AxoDesktop · standalone prototype"));
    title.set_tooltip_text(Some("Local Ghostty terminal; not connected to axod"));
    header.set_title_widget(Some(&title));
    window.set_titlebar(Some(&header));
    let pending = Rc::new(RefCell::new(None::<attachment::AttachmentTask>));
    let closing = Rc::new(Cell::new(false));
    window.connect_close_request({
        let engine = engine.clone();
        let pending = pending.clone();
        let closing = closing.clone();
        move |_| {
            closing.set(true);
            drop(pending.borrow_mut().take());
            // External surfaces detach without confirmation or killing their shell.
            // Standalone surfaces retain Ghostty's busy-child confirmation.
            engine.request_quit();
            glib::Propagation::Stop
        }
    });
    match source {
        TerminalSource::Standalone(command) => {
            let surface = engine.surface(command.as_deref())?;
            install_surface(&window, &surface, options);
        }
        TerminalSource::Attached { socket, shell } => {
            title.set_text(&format!("Shell {shell} · connecting to axod…"));
            title.set_tooltip_text(Some(
                "Closing this window detaches; the daemon keeps the shell running",
            ));
            let weak_window = window.downgrade();
            let engine = engine.clone();
            let options = options.clone();
            let shell = *shell;
            *pending.borrow_mut() = Some(
                attachment::AttachmentTask::start(socket.clone(), shell, move |result| {
                    if closing.get() {
                        return;
                    }
                    if let Some(window) = weak_window.upgrade() {
                        match result
                            .map_err(|error| error.to_string())
                            .and_then(|prepared| engine.attached_surface(prepared))
                        {
                            Ok(surface) => {
                                install_surface(&window, &surface, &options);
                                title.set_text(&format!("Shell {shell} · axod"));
                            }
                            Err(error) => {
                                title.set_text(&format!("Cannot attach shell {shell}"));
                                window.set_child(Some(&gtk4::Label::new(Some(&error))));
                                eprintln!("AxoDesktop: attachment failed: {error}");
                            }
                        }
                    }
                })
                .map_err(|error| format!("cannot start attachment worker: {error}"))?,
            );
        }
    }
    window.present();
    Ok(())
}

fn install_surface(window: &gtk4::ApplicationWindow, surface: &Surface, options: &Options) {
    window.set_child(Some(surface.widget()));
    surface.widget().connect_notify_local(Some("title"), {
        let window = window.downgrade();
        move |surface, _| {
            if let Some(window) = window.upgrade() {
                let title: Option<String> = surface.property("title");
                if let Some(title) = title.filter(|title| !title.is_empty()) {
                    window.set_title(Some(&format!("AxoDesktop · {title}")));
                }
            }
        }
    });
    if options.snapshot.is_some() || options.diagnostics.is_some() {
        observe_window(
            &window,
            &surface,
            options.snapshot.clone(),
            options.diagnostics.clone(),
        );
    }
    surface.focus();
}

fn observe_window(
    window: &gtk4::ApplicationWindow,
    surface: &Surface,
    snapshot: Option<PathBuf>,
    diagnostics: Option<PathBuf>,
) {
    // Retain across frames: WidgetPaintable receives its image during GTK painting.
    let paintable = gtk4::WidgetPaintable::new(Some(window));
    let window = window.downgrade();
    let previous = Cell::new(SurfaceStats::default());
    let snapshot_at = Cell::new(0_i64);
    surface.on_frame(move |stats, time| {
        if stats != previous.replace(stats) {
            if let Some(path) = &diagnostics {
                let data = serde_json::json!({"ready":stats.ready == 1,"columns":stats.columns,"rows":stats.rows,"width":stats.width,"height":stats.height});
                if let Err(error) = std::fs::write(path, data.to_string()) { eprintln!("diagnostics: {error}"); }
            }
        }
        if stats.ready == 1 && time - snapshot_at.get() >= 1_000_000 {
            if let (Some(window), Some(path)) = (window.upgrade(), snapshot.as_ref()) {
                if let Err(error) = save_window(&window, &paintable, path) { eprintln!("snapshot: {error}"); }
                snapshot_at.set(time);
            }
        }
    });
}

fn save_window(
    window: &gtk4::ApplicationWindow,
    paintable: &gtk4::WidgetPaintable,
    path: &Path,
) -> Result<(), String> {
    let snapshot = gtk4::Snapshot::new();
    paintable.snapshot(&snapshot, window.width().into(), window.height().into());
    let node = snapshot
        .to_node()
        .ok_or("window has not produced a render node")?;
    let renderer = window.renderer().ok_or("window has no GSK renderer")?;
    renderer
        .render_texture(&node, None)
        .save_to_png(path)
        .map_err(|error| error.to_string())
}
