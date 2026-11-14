//! Linux desktop access is observed, not inferred from DISPLAY or a matching Unix UID.
use std::time::Duration;

use cua_driver_core::tool::ToolRegistry;
use serde_json::{Value, json};
use zbus::zvariant::OwnedObjectPath;

pub(super) fn registry() -> ToolRegistry {
    // Do not use register_tools(): it can start a nested compositor from inherited env.
    // This builds tools only, with no overlay, telemetry or desktop switching.
    platform_linux::tools::build_registry(false)
}

pub(super) async fn preflight() -> Option<String> {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() && !platform_linux::wayland::wayland_enabled()
    {
        return Some("Not done: native Wayland requires CUA_DRIVER_RS_ENABLE_WAYLAND=1 in axod's desktop-session environment. XWayland DISPLAY is not native desktop control.".into());
    }
    if platform_linux::wayland::is_wayland()
        && platform_linux::wayland::shell_helper::available()
        && !safe_gnome_helper().await
    {
        return Some("Not done: the active WinRects helper is unsafe or unverified for this GNOME version. Keep winrects@cua disabled on GNOME 50 and newer; do not bypass its session-safety guard.".into());
    }
    None
}

fn supported_gnome_version(version: &str) -> bool {
    version
        .split('.')
        .next()
        .and_then(|major| major.parse::<u32>().ok())
        .is_some_and(|major| (45..=49).contains(&major))
}

async fn observe_gnome_helper() -> zbus::Result<bool> {
    let bus = zbus::Connection::session().await?;
    let names = zbus::Proxy::new(
        &bus,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .await?;
    let owner: String = names.call("GetNameOwner", &("org.gnome.Shell",)).await?;
    // Pin the property read to one immutable bus owner, not a replaceable name.
    let shell =
        zbus::Proxy::new(&bus, owner.as_str(), "/org/gnome/Shell", "org.gnome.Shell").await?;
    let version: String = shell.get_property("ShellVersion").await?;
    let helper = zbus::Proxy::new(
        &bus,
        owner.as_str(),
        "/org/cua/WinRects",
        "org.cua.WinRects",
    )
    .await?;
    let api: u32 = helper.call("GetVersion", &()).await?;
    let trusted_helper = platform_linux::wayland::shell_helper::available();
    let current_owner: String = names.call("GetNameOwner", &("org.gnome.Shell",)).await?;
    Ok(trusted_helper
        && owner == current_owner
        && supported_gnome_version(&version)
        && api >= platform_linux::wayland::shell_helper::WINDOW_CAPTURE_API_VERSION)
}

async fn safe_gnome_helper() -> bool {
    matches!(
        tokio::time::timeout(Duration::from_millis(800), observe_gnome_helper()).await,
        Ok(Ok(true))
    )
}

pub(super) fn permissions() -> (bool, bool) {
    let probe = super::native::call("check_permissions", json!({"prompt":false}));
    let status = &probe["structuredContent"];
    let wayland_capture = platform_linux::wayland::wayland_enabled()
        && platform_linux::wayland::shell_helper::available()
        && super::native::block_on(safe_gnome_helper());
    permission_observations(status, wayland_capture)
}

fn permission_observations(status: &Value, wayland_capture: bool) -> (bool, bool) {
    let accessibility = status["atspi"] == true;
    // XWayland is not evidence that native Wayland window capture works. Portal
    // capture consent cannot be inferred from a reachable session bus either.
    let capture = if status["wayland"] == true {
        status["wayland_enabled"] == true && wayland_capture
    } else {
        status["x11"] == true
    };
    (accessibility, capture)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DesktopState {
    Unlocked,
    Locked,
    Unavailable,
}

#[derive(Debug)]
struct Session {
    uid: u32,
    kind: String,
    class: String,
    active: bool,
    locked: bool,
}

fn desktop_state(uid: u32, sessions: &[Session]) -> DesktopState {
    let mut candidates = sessions.iter().filter(|session| {
        session.uid == uid
            && session.active
            && session.class == "user"
            && matches!(session.kind.as_str(), "x11" | "wayland")
    });
    let Some(session) = candidates.next() else {
        return DesktopState::Unavailable;
    };
    if candidates.next().is_some() {
        return DesktopState::Unavailable;
    }
    if session.locked {
        DesktopState::Locked
    } else {
        DesktopState::Unlocked
    }
}

async fn observe_desktop() -> zbus::Result<DesktopState> {
    // SAFETY: geteuid has no pointer or ownership preconditions.
    let uid = unsafe { libc::geteuid() };
    let bus = zbus::Connection::system().await?;
    let manager = zbus::Proxy::new(
        &bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
    )
    .await?;
    let listed: Vec<(String, u32, String, String, OwnedObjectPath)> =
        manager.call("ListSessions", &()).await?;
    let mut sessions = Vec::new();
    for (_, owner, _, _, path) in listed {
        if owner != uid {
            continue;
        }
        let proxy = zbus::Proxy::new(
            &bus,
            "org.freedesktop.login1",
            path,
            "org.freedesktop.login1.Session",
        )
        .await?;
        let kind: String = proxy.get_property("Type").await?;
        if !matches!(kind.as_str(), "x11" | "wayland") {
            continue;
        }
        let (owner, _): (u32, OwnedObjectPath) = proxy.get_property("User").await?;
        sessions.push(Session {
            uid: owner,
            kind,
            class: proxy.get_property("Class").await?,
            active: proxy.get_property("Active").await?,
            locked: proxy.get_property("LockedHint").await?,
        });
    }
    Ok(desktop_state(uid, &sessions))
}

pub(super) async fn locked() -> bool {
    !matches!(
        tokio::time::timeout(Duration::from_secs(2), observe_desktop()).await,
        Ok(Ok(DesktopState::Unlocked))
    )
}

pub fn screen_locked() -> bool {
    super::native::block_on(locked())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(uid: u32, kind: &str, active: bool, locked: bool) -> Session {
        Session {
            uid,
            kind: kind.into(),
            class: "user".into(),
            active,
            locked,
        }
    }

    #[test]
    fn only_one_active_owned_explicitly_unlocked_graphical_session_is_usable() {
        assert_eq!(
            desktop_state(1000, &[session(1000, "wayland", true, false)]),
            DesktopState::Unlocked
        );
        assert_eq!(
            desktop_state(1000, &[session(1000, "x11", true, false)]),
            DesktopState::Unlocked
        );
        assert_eq!(
            desktop_state(1000, &[session(1000, "wayland", true, true)]),
            DesktopState::Locked
        );
        for sessions in [
            vec![],
            vec![session(1001, "wayland", true, false)],
            vec![session(1000, "tty", true, false)],
            vec![session(1000, "wayland", false, false)],
            vec![
                session(1000, "wayland", true, false),
                session(1000, "x11", true, false),
            ],
        ] {
            assert_eq!(desktop_state(1000, &sessions), DesktopState::Unavailable);
        }
        let mut greeter = session(1000, "wayland", true, false);
        greeter.class = "greeter".into();
        assert_eq!(desktop_state(1000, &[greeter]), DesktopState::Unavailable);
    }

    #[test]
    fn unsafe_or_unverified_gnome_versions_never_admit_the_shell_helper() {
        for version in ["45", "48.2", "49.9"] {
            assert!(supported_gnome_version(version));
        }
        for version in [
            "",
            "44.9",
            "50",
            "50.1",
            "51.0",
            "49x",
            "not a version",
            "9999999999999",
        ] {
            assert!(!supported_gnome_version(version), "{version}");
        }
    }

    #[test]
    fn xwayland_and_portal_reachability_do_not_grant_native_wayland_capture() {
        let status = json!({"x11":true,"wayland":true,"wayland_enabled":true,"atspi":true});
        assert_eq!(permission_observations(&status, false), (true, false));
        assert_eq!(permission_observations(&status, true), (true, true));
        assert_eq!(permission_observations(&json!({}), true), (false, false));
        assert_eq!(
            permission_observations(&json!({"x11":true,"atspi":true}), false),
            (true, true)
        );
    }
}
