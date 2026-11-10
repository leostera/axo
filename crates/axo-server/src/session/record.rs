//! How a Session is described to clients: its record's parts that are rules rather than state.

use std::path::{Path, PathBuf};

use axo_protocol::{
    Availability, Layout, LayoutDirection, LayoutNode, PaneRole, SessionStatus, ShellId,
    ShellRecord, new_uuid_v4,
};

/// Shown on a Pi pane whose process could not be recovered.
pub(crate) const UNRECOVERABLE_PI_REASON: &str =
    "Axo could not recover this Pi session. Its conversation history is preserved.";

pub(crate) fn valid_session_title(title: &str) -> bool {
    !title.is_empty()
        && title.trim() == title
        && title.encode_utf16().count() <= 80
        && !title.chars().any(char::is_control)
}

pub(crate) fn valid_session_emoji(emoji: &str) -> bool {
    !emoji.is_empty()
        && emoji.chars().count() <= 16
        && emoji.trim() == emoji
        && !emoji.chars().any(char::is_whitespace)
        && !emoji.chars().any(char::is_control)
}

/// Like the client's `defaultLayout`: the open panes side by side in creation order.
pub(crate) fn default_layout(mut shell_ids: Vec<ShellId>) -> Option<Layout> {
    shell_ids.sort();
    let (first, rest) = shell_ids.split_first()?;
    let mut root = LayoutNode::Pane { shell_id: *first };
    for shell_id in rest {
        root = LayoutNode::Split {
            id: new_uuid_v4().ok()?,
            direction: LayoutDirection::Right,
            ratio: 0.5,
            first: Box::new(root),
            second: Box::new(LayoutNode::Pane {
                shell_id: *shell_id,
            }),
        };
    }
    Layout::try_from(root).ok()
}

/// A Pi pane with no process: dormant (it starts when wanted), or unavailable.
pub(crate) fn idle_pi_record(
    id: ShellId,
    pane_id: Option<String>,
    initial_pwd: PathBuf,
    dormant: bool,
    attach_socket_path: &Path,
) -> ShellRecord {
    ShellRecord {
        id,
        pane_id,
        role: PaneRole::Pi,
        process_id: 0,
        initial_pwd,
        pty_device: String::new(),
        attach_socket_path: attach_socket_path.to_path_buf(),
        availability: if dormant {
            Availability::Dormant
        } else {
            Availability::Unavailable {
                reason: UNRECOVERABLE_PI_REASON.to_owned(),
            }
        },
    }
}

/// The Session's status from its panes and its Pi's activity.
pub(crate) fn status(shells: &[ShellRecord], pi: Option<SessionStatus>) -> SessionStatus {
    if shells
        .iter()
        .any(|shell| matches!(shell.availability, Availability::Unavailable { .. }))
    {
        SessionStatus::Unavailable
    } else if shells
        .iter()
        .any(|shell| shell.availability == Availability::Dormant)
    {
        // Idle, and ready for a prompt, which starts its Pi.
        SessionStatus::Ready
    } else if shells.iter().any(|shell| shell.role == PaneRole::Pi) {
        pi.unwrap_or(SessionStatus::Starting)
    } else {
        SessionStatus::Ready
    }
}

pub(crate) fn file_modification_timestamp(path: &Path) -> Option<i64> {
    std::fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs()
        .try_into()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_and_emoji_are_checked_before_they_are_kept() {
        assert!(valid_session_title("Fix the relay"));
        assert!(!valid_session_title(" padded"));
        assert!(!valid_session_title(&"x".repeat(81)));
        assert!(!valid_session_title("a\nb"));
        assert!(valid_session_emoji("🧹"));
        assert!(!valid_session_emoji("two words"));
    }

    #[test]
    fn the_default_layout_puts_panes_side_by_side_in_creation_order() {
        let layout =
            default_layout(vec![ShellId::new(3).unwrap(), ShellId::new(2).unwrap()]).unwrap();
        assert_eq!(layout.shell_ids().len(), 2);
        assert!(default_layout(Vec::new()).is_none());
    }
}
