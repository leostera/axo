//! Native MLX binding, independent of the daemon and cloud API. Only the Apple Silicon
//! configuration references or links MLX; other targets have no native or JSON dependency.
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
#[path = "mlx.rs"]
mod native;
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
pub use native::{Model, Runtime};

pub const COMPILED: bool = cfg!(all(target_os = "macos", target_arch = "aarch64"));

/// Build identity, not a promise that a particular model/head or Metal device will load.
pub struct BuildInfo {
    pub name: &'static str,
    pub version: Option<String>,
    pub commit: Option<String>,
    pub compiled: bool,
    pub reason: Option<&'static str>,
}

pub fn build_info() -> BuildInfo {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let info: serde_json::Value =
            serde_json::from_str(include_str!(env!("AXO_MLX_CAPABILITIES")))
                .expect("the pinned MLX build emits valid JSON");
        BuildInfo {
            name: "mlx",
            compiled: true,
            version: Some(info["version"].as_str().expect("pinned version").into()),
            commit: Some(info["commit"].as_str().expect("pinned commit").into()),
            reason: None,
        }
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        BuildInfo {
            name: "mlx",
            compiled: false,
            version: None,
            commit: None,
            reason: Some("native MLX requires macOS on Apple Silicon"),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn build_identity_agrees_with_the_target_configuration() {
        let info = super::build_info();
        assert_eq!(info.compiled, super::COMPILED);
        assert_eq!(info.name, "mlx");
        assert_eq!(info.version.is_some(), super::COMPILED);
    }
}
