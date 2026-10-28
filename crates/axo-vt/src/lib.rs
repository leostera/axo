//! A headless terminal, backed by libghostty-vt from the pinned Ghostty build.
//!
//! Axod feeds every byte a PTY writes into one of these, so it always knows the screen the
//! program has drawn: modes (alternate screen, mouse reporting, bracketed paste…), contents,
//! scrollback, cursor and keyboard state. A client attaching later receives [`Terminal::snapshot`]
//! instead of the raw byte history, which tmux, zellij and mosh do the same way.
//!
//! The emulator never answers the program: queries such as device attributes are dropped
//! (libghostty-vt's default without a `write_pty` callback). The attached Ghostty surface parses
//! the same live bytes and is the one that responds.

use std::ffi::{c_int, c_void};
use std::fmt;
use std::ptr;

/// Bytes of unfinished escape sequence the emulator retains so a snapshot can resume it.
/// Large enough for an image transmission in flight; memory is only used while one is.
pub const CONTINUATION_MAX_BYTES: usize = 4 * 1024 * 1024;

/// A libghostty-vt call failed; the code is its `GhosttyResult`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Error {
    pub operation: &'static str,
    pub code: i32,
}

impl fmt::Display for Error {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "libghostty-vt {} failed ({})",
            self.operation, self.code
        )
    }
}

impl std::error::Error for Error {}

/// A terminal grid size in cells. Both dimensions are at least one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GridSize {
    pub columns: u16,
    pub rows: u16,
}

impl GridSize {
    /// `None` for a zero dimension, which libghostty-vt rejects.
    pub fn new(columns: u16, rows: u16) -> Option<Self> {
        (columns > 0 && rows > 0).then_some(Self { columns, rows })
    }
}

/// One headless terminal. Not thread-safe by itself: callers serialize access, as Axod does under
/// its output lock.
pub struct Terminal {
    raw: ffi::Terminal,
    size: GridSize,
}

// SAFETY: a libghostty-vt terminal has no thread affinity; `&mut self` (and the owner's lock)
// serializes every call.
unsafe impl Send for Terminal {}

impl Terminal {
    /// A terminal of `size` keeping at most `scrollback_max_bytes` of history.
    pub fn new(size: GridSize, scrollback_max_bytes: usize) -> Result<Self, Error> {
        let mut raw = ptr::null_mut();
        // SAFETY: `raw` is a valid out pointer; a null allocator selects the default one.
        check("terminal_new", unsafe {
            ffi::ghostty_terminal_new(ptr::null(), &mut raw, size.columns, size.rows)
        })?;
        let mut terminal = Self { raw, size };
        terminal.set_size_option(ffi::OPT_CONTINUATION_MAX_BYTES, CONTINUATION_MAX_BYTES)?;
        terminal.set_scrollback_max_bytes(scrollback_max_bytes)?;
        Ok(terminal)
    }

    pub fn size(&self) -> GridSize {
        self.size
    }

    /// Parses program output.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: `bytes` is valid for its length and the terminal is live.
        unsafe { ffi::ghostty_terminal_vt_write(self.raw, bytes.as_ptr(), bytes.len()) }
    }

    /// Resizes the grid, reflowing the primary screen as a terminal does. Unchanged sizes are
    /// skipped: libghostty-vt still treats them as a resize (ending synchronized output).
    pub fn resize(&mut self, size: GridSize) -> Result<(), Error> {
        if size == self.size {
            return Ok(());
        }
        // SAFETY: the terminal is live; zero pixel sizes only affect pixel size reports.
        check("terminal_resize", unsafe {
            ffi::ghostty_terminal_resize(self.raw, size.columns, size.rows, 0, 0)
        })?;
        self.size = size;
        Ok(())
    }

    /// Lowers or raises the history limit. Lowering drops the oldest history immediately.
    pub fn set_scrollback_max_bytes(&mut self, bytes: usize) -> Result<(), Error> {
        self.set_size_option(ffi::OPT_SCROLLBACK_MAX_BYTES, bytes)
    }

    /// VT bytes that rebuild this terminal's state in a fresh terminal of the same size, followed
    /// by any unfinished escape sequence, so the program's next bytes continue it seamlessly.
    ///
    /// Everything that shapes how the program's later output and input behave is included:
    /// modes, the active screen with its scrollback, scrolling region, tab stops, keyboard
    /// protocols, cursor, style, hyperlink and character sets. The palette is not: it would
    /// replace the attaching terminal's theme with the emulator's defaults.
    pub fn snapshot(&mut self) -> Result<Vec<u8>, Error> {
        let options = ffi::FormatterTerminalOptions {
            size: size_of::<ffi::FormatterTerminalOptions>(),
            emit: ffi::FORMAT_VT,
            // Soft-wrapped rows are emitted joined, so the client wraps them itself and keeps
            // them soft-wrapped (and reflowable) at the same width.
            unwrap: true,
            trim: false,
            extra: ffi::TerminalExtra {
                size: size_of::<ffi::TerminalExtra>(),
                palette: false,
                modes: true,
                scrolling_region: true,
                tabstops: true,
                pwd: true,
                keyboard: true,
                screen: ffi::ScreenExtra {
                    size: size_of::<ffi::ScreenExtra>(),
                    cursor: true,
                    style: true,
                    hyperlink: true,
                    protection: true,
                    kitty_keyboard: true,
                    charsets: true,
                },
            },
            selection: ptr::null(),
        };
        let mut formatter = ptr::null_mut();
        // SAFETY: the terminal outlives the formatter, which is freed below.
        check("formatter_terminal_new", unsafe {
            ffi::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, options)
        })?;
        let screen = take_allocated("formatter_format_alloc", |out, len| unsafe {
            // SAFETY: the formatter is live and the out pointers are valid.
            ffi::ghostty_formatter_format_alloc(formatter, ptr::null(), out, len)
        });
        // SAFETY: created above and not used after this.
        unsafe { ffi::ghostty_formatter_free(formatter) };
        let mut snapshot = screen?;
        let continuation = take_allocated("terminal_continuation_alloc", |out, len| unsafe {
            // SAFETY: the terminal is live and the out pointers are valid.
            ffi::ghostty_terminal_continuation_alloc(self.raw, ptr::null(), out, len)
        })?;
        snapshot.extend_from_slice(&continuation);
        Ok(snapshot)
    }

    /// The screen and its scrollback as plain text: soft-wrapped rows joined, trailing blanks
    /// trimmed, no styling or escape sequences. What a person would copy out of the terminal.
    pub fn plain_text(&mut self) -> Result<String, Error> {
        let screen = ffi::ScreenExtra {
            size: size_of::<ffi::ScreenExtra>(),
            cursor: false,
            style: false,
            hyperlink: false,
            protection: false,
            kitty_keyboard: false,
            charsets: false,
        };
        let options = ffi::FormatterTerminalOptions {
            size: size_of::<ffi::FormatterTerminalOptions>(),
            emit: ffi::FORMAT_PLAIN,
            unwrap: true,
            trim: true,
            extra: ffi::TerminalExtra {
                size: size_of::<ffi::TerminalExtra>(),
                palette: false,
                modes: false,
                scrolling_region: false,
                tabstops: false,
                pwd: false,
                keyboard: false,
                screen,
            },
            selection: ptr::null(),
        };
        let mut formatter = ptr::null_mut();
        // SAFETY: the terminal outlives the formatter, which is freed below.
        check("formatter_terminal_new", unsafe {
            ffi::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, options)
        })?;
        let text = take_allocated("formatter_format_alloc", |out, len| unsafe {
            // SAFETY: the formatter is live and the out pointers are valid.
            ffi::ghostty_formatter_format_alloc(formatter, ptr::null(), out, len)
        });
        // SAFETY: created above and not used after this.
        unsafe { ffi::ghostty_formatter_free(formatter) };
        Ok(String::from_utf8_lossy(&text?).into_owned())
    }

    fn set_size_option(&mut self, option: c_int, value: usize) -> Result<(), Error> {
        // SAFETY: both options read a `size_t` through the pointer during the call.
        check("terminal_set", unsafe {
            ffi::ghostty_terminal_set(self.raw, option, (&value as *const usize).cast())
        })
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        // SAFETY: the terminal is live and freed exactly once.
        unsafe { ffi::ghostty_terminal_free(self.raw) }
    }
}

fn check(operation: &'static str, code: c_int) -> Result<(), Error> {
    if code == ffi::SUCCESS {
        Ok(())
    } else {
        Err(Error { operation, code })
    }
}

/// Copies and frees a buffer a libghostty-vt `_alloc` function returned with the default
/// allocator. Empty results come back as a null pointer and zero length.
fn take_allocated(
    operation: &'static str,
    call: impl FnOnce(*mut *mut u8, *mut usize) -> c_int,
) -> Result<Vec<u8>, Error> {
    let mut data = ptr::null_mut();
    let mut len = 0;
    check(operation, call(&mut data, &mut len))?;
    if data.is_null() {
        return Ok(Vec::new());
    }
    // SAFETY: libghostty-vt returned `len` initialized bytes at `data`.
    let bytes = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
    // SAFETY: allocated by the default allocator with exactly this length.
    unsafe { ffi::ghostty_free(ptr::null(), data, len) };
    Ok(bytes)
}

/// The subset of `ghostty/vt.h` Axod uses, at the pinned Ghostty commit.
mod ffi {
    use super::{c_int, c_void};

    pub type Terminal = *mut c_void;
    pub type Formatter = *mut c_void;

    pub const SUCCESS: c_int = 0;
    /// `GHOSTTY_FORMATTER_FORMAT_PLAIN`.
    pub const FORMAT_PLAIN: c_int = 0;
    /// `GHOSTTY_FORMATTER_FORMAT_VT`.
    pub const FORMAT_VT: c_int = 1;
    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`.
    pub const OPT_SCROLLBACK_MAX_BYTES: c_int = 27;
    /// `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES`.
    pub const OPT_CONTINUATION_MAX_BYTES: c_int = 31;

    /// `GhosttyFormatterScreenExtra`.
    #[repr(C)]
    pub struct ScreenExtra {
        pub size: usize,
        pub cursor: bool,
        pub style: bool,
        pub hyperlink: bool,
        pub protection: bool,
        pub kitty_keyboard: bool,
        pub charsets: bool,
    }

    /// `GhosttyFormatterTerminalExtra`.
    #[repr(C)]
    pub struct TerminalExtra {
        pub size: usize,
        pub palette: bool,
        pub modes: bool,
        pub scrolling_region: bool,
        pub tabstops: bool,
        pub pwd: bool,
        pub keyboard: bool,
        pub screen: ScreenExtra,
    }

    /// `GhosttyFormatterTerminalOptions`.
    #[repr(C)]
    pub struct FormatterTerminalOptions {
        pub size: usize,
        pub emit: c_int,
        pub unwrap: bool,
        pub trim: bool,
        pub extra: TerminalExtra,
        pub selection: *const c_void,
    }

    unsafe extern "C" {
        pub fn ghostty_terminal_new(
            allocator: *const c_void,
            terminal: *mut Terminal,
            cols: u16,
            rows: u16,
        ) -> c_int;
        pub fn ghostty_terminal_free(terminal: Terminal);
        pub fn ghostty_terminal_resize(
            terminal: Terminal,
            cols: u16,
            rows: u16,
            cell_width_px: u32,
            cell_height_px: u32,
        ) -> c_int;
        pub fn ghostty_terminal_set(
            terminal: Terminal,
            option: c_int,
            value: *const c_void,
        ) -> c_int;
        pub fn ghostty_terminal_vt_write(terminal: Terminal, data: *const u8, len: usize);
        pub fn ghostty_terminal_continuation_alloc(
            terminal: Terminal,
            allocator: *const c_void,
            out_ptr: *mut *mut u8,
            out_len: *mut usize,
        ) -> c_int;
        pub fn ghostty_formatter_terminal_new(
            allocator: *const c_void,
            formatter: *mut Formatter,
            terminal: Terminal,
            options: FormatterTerminalOptions,
        ) -> c_int;
        pub fn ghostty_formatter_format_alloc(
            formatter: Formatter,
            allocator: *const c_void,
            out_ptr: *mut *mut u8,
            out_len: *mut usize,
        ) -> c_int;
        pub fn ghostty_formatter_free(formatter: Formatter);
        pub fn ghostty_free(allocator: *const c_void, ptr: *mut u8, len: usize);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIB: usize = 1024 * 1024;

    fn terminal(columns: u16, rows: u16) -> Terminal {
        Terminal::new(GridSize::new(columns, rows).unwrap(), MIB).unwrap()
    }

    /// Replaying a snapshot into a fresh terminal must rebuild the same state: the snapshot of
    /// the copy equals the snapshot of the original.
    fn assert_round_trips(original: &mut Terminal) -> Vec<u8> {
        let snapshot = original.snapshot().unwrap();
        let mut copy = Terminal::new(original.size(), MIB).unwrap();
        copy.write(&snapshot);
        assert_eq!(
            String::from_utf8_lossy(&copy.snapshot().unwrap()),
            String::from_utf8_lossy(&snapshot),
        );
        snapshot
    }

    fn contains(haystack: &[u8], needle: &str) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle.as_bytes())
    }

    #[test]
    fn zero_dimensions_are_not_a_grid_size() {
        assert_eq!(GridSize::new(0, 24), None);
        assert_eq!(GridSize::new(80, 0), None);
    }

    #[test]
    fn snapshot_restores_a_full_screen_program_and_its_input_modes() {
        let mut original = terminal(40, 10);
        // What Pi's fullscreen TUI writes once at startup, then a frame.
        original
            .write(b"\x1b[?1049h\x1b[?7l\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?2004h");
        original.write(b"\x1b[>7u\x1b[2J\x1b[H\x1b[1mPi transcript\x1b[0m\r\n> prompt");

        let snapshot = assert_round_trips(&mut original);

        for mode in [
            "\x1b[?1049h",
            "\x1b[?1000h",
            "\x1b[?1003h",
            "\x1b[?1006h",
            "\x1b[?2004h",
            "\x1b[?7l",
        ] {
            assert!(contains(&snapshot, mode), "snapshot must restore {mode:?}");
        }
        assert!(contains(&snapshot, "Pi transcript"));
        assert!(contains(&snapshot, "> prompt"));
    }

    #[test]
    fn plain_text_is_what_the_program_printed_without_styling() {
        let mut terminal = terminal(20, 4);
        for line in 0..6 {
            terminal.write(format!("\x1b[1mline\x1b[0m {line}\r\n").as_bytes());
        }
        terminal.write(b"a long row that wraps past twenty columns");
        let text = terminal.plain_text().unwrap();
        assert!(text.starts_with("line 0\nline 1\n"), "{text:?}");
        assert!(
            text.ends_with("line 5\na long row that wraps past twenty columns"),
            "{text:?}"
        );
        assert!(!text.contains('\x1b'));
    }

    #[test]
    fn snapshot_keeps_primary_screen_scrollback() {
        let mut original = terminal(20, 4);
        for line in 0..50 {
            original.write(format!("line {line}\r\n").as_bytes());
        }
        let snapshot = assert_round_trips(&mut original);
        assert!(
            contains(&snapshot, "line 0\r\n"),
            "history above the viewport is kept"
        );
        assert!(contains(&snapshot, "line 49"));
    }

    #[test]
    fn snapshot_resumes_an_escape_sequence_split_across_writes() {
        let mut original = terminal(20, 4);
        original.write(b"before \x1b[3");
        let snapshot = original.snapshot().unwrap();
        assert!(
            snapshot.ends_with(b"\x1b[3"),
            "the unfinished sequence is carried over"
        );

        // A client parsing the snapshot and then the rest of the stream ends up like Axod.
        let mut copy = terminal(20, 4);
        copy.write(&snapshot);
        copy.write(b"1mred");
        original.write(b"1mred");
        assert_eq!(copy.snapshot().unwrap(), original.snapshot().unwrap());
    }

    #[test]
    fn resize_reflows_like_the_client_does() {
        let mut original = terminal(10, 4);
        original.write(b"0123456789abcdef");
        original.resize(GridSize::new(20, 4).unwrap()).unwrap();
        assert_eq!(original.size(), GridSize::new(20, 4).unwrap());
        let snapshot = assert_round_trips(&mut original);
        assert!(
            contains(&snapshot, "0123456789abcdef"),
            "soft wrap is undone on widening"
        );
    }

    #[test]
    fn lowering_the_scrollback_limit_drops_history() {
        let mut original = terminal(80, 4);
        for line in 0..20_000 {
            original.write(format!("history line {line}\r\n").as_bytes());
        }
        let before = original.snapshot().unwrap().len();
        original.set_scrollback_max_bytes(0).unwrap();
        let after = original.snapshot().unwrap();
        assert!(after.len() < before);
        assert!(!contains(&after, "history line 0\r\n"));
        assert!(contains(&after, "history line 19999"));
    }
}
