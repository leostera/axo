//! What the uploader knows of each Session: the metadata the cloud lists it by, its Workspace's
//! folder and repository, and what `axo.db` keeps of the cloud's acknowledgements.

use std::path::PathBuf;

use axo_protocol::{SessionId, SessionStatus};
use serde::{Deserialize, Serialize};

use super::is_uuid;

/// What the cloud lists a Session by. The host owns it, and raises its version on every change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMetadata {
    pub name: Option<String>,
    pub emoji: Option<String>,
    pub workspace_id: Option<String>,
    pub workspace_name: Option<String>,
    pub has_agent: bool,
    pub created_at: Option<i64>,
    pub last_message_at: Option<i64>,
    pub archived: bool,
    /// Where the Session's work is, as git saw it after the agent last settled (RFD0022). Absent
    /// means not known yet; the last known state is then kept, never erased.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_state: Option<WorkspaceState>,
    /// What the Session's Pi runs, as it last said (RFD0033). Absent means not known now; the
    /// last known state is then kept, as a workspace state is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pi: Option<axo_protocol::PiRuntime>,
}

/// A Session's folder and its repository, so another Mac can tell what it would need to continue
/// the Session (RFD0022). Outside a repository only `path` is set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceState {
    pub path: String,
    pub repo_root: Option<String>,
    /// The upstream remote's URL, with any credentials removed.
    pub remote: Option<String>,
    /// None when HEAD is detached.
    pub branch: Option<String>,
    pub head: Option<String>,
    /// Where the branch's upstream was, as last fetched on this Mac.
    pub upstream_head: Option<String>,
    /// Paths `git status` lists, at most `WorkspaceState::MAX_DIRTY`.
    pub dirty: Vec<String>,
    /// Paths beyond those in `dirty`.
    pub dirty_more: u32,
    /// Unix seconds.
    pub at: i64,
}

impl WorkspaceState {
    pub const MAX_DIRTY: usize = 50;
    const MAX_PATH: usize = 1024;

    fn bounded(mut self) -> Self {
        let path = |value: String| value.chars().take(Self::MAX_PATH).collect::<String>();
        let short = |value: Option<String>, max: usize| {
            value.filter(|value| !value.is_empty() && value.chars().count() <= max)
        };
        let hash = |value: Option<String>| {
            value.filter(|value| {
                (7..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit())
            })
        };
        self.path = path(self.path);
        self.repo_root = self.repo_root.map(path);
        self.remote = short(self.remote, Self::MAX_PATH);
        self.branch = short(self.branch, 255);
        self.head = hash(self.head);
        self.upstream_head = hash(self.upstream_head);
        let total = self.dirty.len() as u32 + self.dirty_more;
        self.dirty.truncate(Self::MAX_DIRTY);
        self.dirty = self.dirty.into_iter().map(path).collect();
        self.dirty_more = total - self.dirty.len() as u32;
        self.at = self.at.max(0);
        self
    }
}

impl SessionMetadata {
    /// Fits the cloud's bounds: a field that does not is left out rather than refused.
    pub fn bounded(mut self) -> Self {
        self.name = self
            .name
            .map(|name| name.trim().chars().take(80).collect::<String>())
            .filter(|name| !name.is_empty());
        self.emoji = self.emoji.filter(|emoji| {
            !emoji.is_empty()
                && emoji.chars().count() <= 16
                && !emoji.chars().any(|c| c.is_whitespace() || c.is_control())
        });
        self.workspace_id = self.workspace_id.filter(|id| is_uuid(id));
        self.workspace_name = self
            .workspace_name
            .map(|name| name.chars().take(80).collect());
        self.created_at = self.created_at.filter(|at| *at >= 0);
        self.last_message_at = self.last_message_at.filter(|at| *at >= 0);
        self.workspace_state = self.workspace_state.map(WorkspaceState::bounded);
        self
    }

    /// A state not known now (axod restarted, or the Session is archived) is the one known before:
    /// the workspace's, and what its Pi runs.
    pub(super) fn keep_workspace_state(&mut self, before: &SessionMetadata) {
        if self.workspace_state.is_none() {
            self.workspace_state = before.workspace_state.clone();
        }
        if self.pi.is_none() {
            self.pi = before.pi.clone();
        }
    }
}

/// One Session as the uploader sees it: open or archived, with its Pi transcript.
#[derive(Clone, Debug, PartialEq)]
pub struct SyncSession {
    pub session_id: SessionId,
    pub pi_session_file: Option<PathBuf>,
    pub metadata: SessionMetadata,
    /// Open Sessions only: what the Mac shows.
    pub status: Option<SessionStatus>,
    /// Deleted here and held by the cloud (RFD0027): nothing is uploaded, nor read.
    pub transcript_in_cloud: bool,
}

/// What `axo.db` keeps per Session: the last position and chain the cloud acknowledged, and the
/// metadata last sent with its version.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct StoredSyncState {
    pub session_id: String,
    pub position: u64,
    pub chain: Option<String>,
    pub metadata_json: Option<String>,
    pub metadata_version: u64,
    pub in_cloud: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(head: &str) -> WorkspaceState {
        WorkspaceState {
            path: "/Users/leo/src/axo".into(),
            repo_root: Some("/Users/leo/src/axo".into()),
            remote: Some("https://github.com/leostera/axo.git".into()),
            branch: Some("main".into()),
            head: Some(head.into()),
            upstream_head: None,
            dirty: Vec::new(),
            dirty_more: 0,
            at: 1,
        }
    }

    fn listed(workspace_state: Option<WorkspaceState>) -> SessionMetadata {
        SessionMetadata {
            name: Some("Relay".into()),
            emoji: None,
            workspace_id: None,
            workspace_name: None,
            has_agent: true,
            created_at: None,
            last_message_at: None,
            archived: false,
            workspace_state,
            pi: None,
        }
    }

    #[test]
    fn a_workspace_state_not_known_now_is_the_one_known_before() {
        let before = listed(Some(state("3f2c1aa")));
        let mut now = listed(None);
        now.keep_workspace_state(&before);
        assert_eq!(now, before, "unchanged, so the version is not raised");
        let mut read = listed(Some(state("9e01b2c")));
        read.keep_workspace_state(&before);
        assert_eq!(
            read.workspace_state,
            Some(state("9e01b2c")),
            "a new read replaces it"
        );
    }

    #[test]
    fn what_pi_runs_not_known_now_is_what_it_ran_before() {
        let opus = axo_protocol::PiRuntime {
            model: Some(axo_protocol::PiModelRef {
                provider: "anthropic".into(),
                id: "claude-opus-4-1".into(),
                name: "Opus 4.1".into(),
            }),
            thinking_level: axo_protocol::ThinkingLevel::High,
        };
        let before = SessionMetadata {
            pi: Some(opus.clone()),
            ..listed(None)
        };
        let mut now = listed(None);
        now.keep_workspace_state(&before);
        assert_eq!(
            now.pi,
            Some(opus),
            "a Pi that has not said yet keeps its last model"
        );
        assert!(
            serde_json::to_value(listed(None))
                .unwrap()
                .get("pi")
                .is_none()
        );
    }

    #[test]
    fn a_workspace_state_fits_the_clouds_bounds() {
        let mut wide = state("not-a-hash");
        wide.dirty = (0..60).map(|n| format!("file{n}.rs")).collect();
        wide.dirty_more = 5;
        wide.branch = Some("b".repeat(300));
        let bounded = listed(Some(wide)).bounded().workspace_state.unwrap();
        assert_eq!(bounded.head, None);
        assert_eq!(bounded.branch, None);
        assert_eq!((bounded.dirty.len(), bounded.dirty_more), (50, 15));
        // Absent stays absent on the wire, so a cloud without the field still takes the metadata.
        let json = serde_json::to_value(listed(None)).unwrap();
        assert!(json.get("workspaceState").is_none());
    }

    #[test]
    fn metadata_outside_the_clouds_bounds_is_left_out() {
        let metadata = SessionMetadata {
            name: Some("  ".into()),
            emoji: Some("a b".into()),
            workspace_id: Some("not-a-uuid".into()),
            workspace_name: Some("w".repeat(100)),
            has_agent: true,
            created_at: Some(-1),
            last_message_at: Some(5),
            archived: false,
            workspace_state: None,
            pi: None,
        }
        .bounded();
        assert_eq!(metadata.name, None);
        assert_eq!(metadata.emoji, None);
        assert_eq!(metadata.workspace_id, None);
        assert_eq!(metadata.workspace_name.unwrap().chars().count(), 80);
        assert_eq!(metadata.created_at, None);
        assert_eq!(metadata.last_message_at, Some(5));
    }
}
