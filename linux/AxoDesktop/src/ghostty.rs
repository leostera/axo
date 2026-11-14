//! Main-thread-only ownership of the private Ghostty GTK bridge.
use gtk4::{
    glib::translate::{ToGlibPtr, from_glib_none},
    prelude::*,
};
use std::{
    ffi::{CString, c_char, c_int, c_void},
    marker::PhantomData,
    ptr::NonNull,
    rc::Rc,
};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SurfaceStats {
    pub ready: u32,
    pub columns: u32,
    pub rows: u32,
    pub width: u32,
    pub height: u32,
}

unsafe extern "C" {
    fn axo_gtk_engine_new() -> *mut c_void;
    fn axo_gtk_application(engine: *mut c_void) -> *mut gtk4::ffi::GtkApplication;
    fn axo_gtk_surface_new(
        engine: *mut c_void,
        command: *const c_char,
    ) -> *mut gtk4::ffi::GtkWidget;
    fn axo_gtk_surface_focus(widget: *mut gtk4::ffi::GtkWidget);
    fn axo_gtk_run(engine: *mut c_void) -> c_int;
    fn axo_gtk_request_quit(engine: *mut c_void);
    fn axo_gtk_surface_stats(widget: *mut gtk4::ffi::GtkWidget, out: *mut SurfaceStats);
    fn axo_gtk_engine_free(engine: *mut c_void) -> c_int;
}

pub struct Surface {
    widget: gtk4::Widget,
}

impl Surface {
    pub fn widget(&self) -> &gtk4::Widget {
        &self.widget
    }

    pub fn focus(&self) {
        self.widget.connect_map(|widget| {
            // SAFETY: map is attached only to this Ghostty widget.
            unsafe { axo_gtk_surface_focus(widget.to_glib_none().0) };
        });
        // SAFETY: this is a live Ghostty widget on the main thread.
        unsafe { axo_gtk_surface_focus(self.widget.to_glib_none().0) };
    }

    pub fn on_frame(&self, observe: impl Fn(SurfaceStats, i64) + 'static) {
        // The callback is attached only to a widget constructed by this module; it
        // does not capture a strong reference to that widget and create a cycle.
        self.widget.add_tick_callback(move |widget, clock| {
            let mut result = SurfaceStats::default();
            // SAFETY: this callback's widget is always the original Ghostty Surface.
            unsafe { axo_gtk_surface_stats(widget.to_glib_none().0, &mut result) };
            observe(result, clock.frame_time());
            gtk4::glib::ControlFlow::Continue
        });
    }
}

pub struct Engine {
    raw: Option<NonNull<c_void>>,
    // GTK and the underlying Ghostty application must never migrate to another thread.
    _main_thread: PhantomData<Rc<()>>,
}

impl Engine {
    pub fn new() -> Result<Self, String> {
        // SAFETY: called once, on the process main thread, before other GTK work.
        let raw = NonNull::new(unsafe { axo_gtk_engine_new() })
            .ok_or("Ghostty GTK initialization failed; inspect stderr")?;
        Ok(Self {
            raw: Some(raw),
            _main_thread: PhantomData,
        })
    }

    fn pointer(&self) -> *mut c_void {
        self.raw
            .expect("engine must remain live until its widgets are released")
            .as_ptr()
    }

    pub fn application(&self) -> gtk4::Application {
        // SAFETY: native app is live; from_glib_none takes a separate GObject reference.
        unsafe { from_glib_none(axo_gtk_application(self.pointer())) }
    }

    pub fn surface(self: &Rc<Self>, command: Option<&str>) -> Result<Surface, String> {
        let command = command
            .map(CString::new)
            .transpose()
            .map_err(|_| "command contains a NUL byte")?;
        // SAFETY: command remains live for the call; native Surface.new clones it.
        let pointer = unsafe {
            axo_gtk_surface_new(
                self.pointer(),
                command.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()),
            )
        };
        if pointer.is_null() {
            return Err("could not create Ghostty's GTK widget".into());
        }
        // SAFETY: widget is a floating GtkWidget; gtk-rs sinks and owns its reference.
        let widget: gtk4::Widget = unsafe { from_glib_none(pointer) };
        // Retain the engine until the GObject itself dies, not just this Rust wrapper:
        // GTK parents/other widget references can outlive Surface, even before realize.
        // SAFETY: this private key is written once here and never retrieved/replaced.
        unsafe { widget.set_data("axo-desktop-private-engine-owner", self.clone()) };
        Ok(Surface { widget })
    }

    pub fn run(&self) -> Result<(), String> {
        // SAFETY: keeps Ghostty's own GLib/core event-loop integration intact.
        if unsafe { axo_gtk_run(self.pointer()) } == 0 {
            Ok(())
        } else {
            Err("Ghostty GTK event loop failed".into())
        }
    }

    pub fn request_quit(&self) {
        // SAFETY: engine is live and access is restricted to the main thread.
        unsafe { axo_gtk_request_quit(self.pointer()) };
    }

    pub fn finish(&mut self) -> Result<(), String> {
        let Some(raw) = self.raw else {
            return Ok(());
        };
        // SAFETY: main destroys its windows and disconnects callbacks before finishing.
        if unsafe { axo_gtk_engine_free(raw.as_ptr()) } != 0 {
            return Err("refusing teardown: a Ghostty surface is still referenced".into());
        }
        self.raw = None;
        Ok(())
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        if let Err(error) = self.finish() {
            // Refuse a use-after-free. Explicit finish makes this a failing smoke test too.
            eprintln!("AxoDesktop: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn surface_stats_matches_the_private_c_abi() {
        assert_eq!(std::mem::size_of::<super::SurfaceStats>(), 20);
        assert_eq!(std::mem::align_of::<super::SurfaceStats>(), 4);
    }
}
