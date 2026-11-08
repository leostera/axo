// Match each platform’s Codex transport without replacing the Unix TUI fixture.
#[cfg(unix)]
include!("fake_codex_unix.rs");
#[cfg(windows)]
include!("fake_codex_windows.rs");
