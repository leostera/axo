//! Direct system Core ML binding. Non-macOS builds import neither Apple code nor JSON.
#[cfg(target_os = "macos")]
#[path = "coreml.rs"]
mod native;
#[cfg(target_os = "macos")]
pub use native::{Model, probe};

pub const COMPILED: bool = cfg!(target_os = "macos");

pub fn unavailable_reason() -> Option<&'static str> {
    if COMPILED {
        None
    } else {
        Some("Core ML requires macOS")
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn platform_boundary_reports_actual_compilation() {
        assert_eq!(super::COMPILED, cfg!(target_os = "macos"));
        assert_eq!(super::unavailable_reason().is_none(), super::COMPILED);
    }
}
