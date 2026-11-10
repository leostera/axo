//! What every part of axod shares (RFD0041): the store, events, the catalog, where things live,
//! and the services that are not about any one Session: questions, computer use, this Mac's input
//! key, the account's assets, and each folder's git state. Nothing here holds a lock across
//! anything slow; each Session's own state is its task's.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use axo_computer_use::{ComputerHost, ComputerUse};
use axo_protocol::elicitation::{Asker, ElicitationOutcome, InputRequest};
use axo_protocol::{Event, SessionId, Viewport};
use axo_questions::{Questions, QuestionsHost, Values};
use jsonrpc_core::Error as RpcError;
use tokio::sync::{Notify, watch};

use crate::catalog::Catalog;
use crate::events::Events;
use crate::peers::Peers;
use crate::settings::Settings;
use crate::store::Store;
use crate::transcripts::PiDirectories;
use crate::workspace_state::WorkspaceStates;

/// Where the input key is kept, by the host credential store.
const INPUT_KEY_ID: &str = "a5c1e7d0-5e4b-4c1f-9d3a-1f0b2c3d4e5f";
/// How long a focus a Pi's `/resume` asked for is handed to a client that lists Sessions.
const PENDING_FOCUS_LIFETIME: Duration = Duration::from_secs(10);

pub(crate) struct Core {
    pub(crate) store: Store,
    pub(crate) events: Events,
    pub(crate) catalog: Catalog,
    /// The open Sessions' tasks.
    pub(crate) registry: crate::sessions::Registry,
    pub(crate) host_id: String,
    /// This run's identity of the Mac, new each start.
    pub(crate) host_generation: String,
    /// The user's home directory, canonical: where a Session starts when nothing says where.
    pub(crate) home: PathBuf,
    pub(crate) attach_socket_path: PathBuf,
    /// Where axod listens, for agents that call back into it (RFD0015).
    pub(crate) agent_socket: PathBuf,
    pub(crate) pi_directories: PiDirectories,
    /// Every Mac's transcripts by host (RFD0022); other Macs' are copies.
    pub(crate) sessions_directory: PathBuf,
    pub(crate) settings: Mutex<Settings>,
    /// The latest client's terminal area; panes no client is attached to are sized from it.
    pub(crate) viewport: watch::Sender<Option<Viewport>>,
    /// Every Pi holds its read end, and goes when axod does (RFD0041).
    pub(crate) lifeline: axo_agent::Lifeline,
    /// Notified when something changes in the bridge sockets' directory.
    pub(crate) bridges_changed: Arc<Notify>,
    /// Who prompted whom, for the agents' rate limits.
    pub(crate) provenance: Mutex<crate::session::prompts::PromptProvenance>,
    /// Archived Sessions being reopened: their transcripts are not deleted meanwhile (RFD0027).
    pub(crate) reopening: Mutex<HashSet<SessionId>>,
    /// Each Session's folder as git saw it when its agent last settled (RFD0022).
    pub(crate) workspace_states: WorkspaceStates,
    /// The other Macs and their Sessions' panes here (RFD0024).
    pub(crate) peers: Peers,
    /// What agents here are asking the person (RFD0029).
    pub(crate) questions: Arc<Questions>,
    /// Computer use here (RFD0028).
    pub(crate) computer: Arc<ComputerUse>,
    /// The account's assets while the relay is connected (RFD0030).
    pub(crate) assets: Arc<axo_assets::AssetSlot>,
    input_key: OnceLock<axo_seal::InputKey>,
    input_key_store: OnceLock<Arc<dyn axo_relay::credential::HostCredentialStore>>,
    /// The focus a Pi's `/resume` asked for, for clients that list rather than stream.
    pending_focus: Mutex<Option<(SessionId, Instant)>>,
    /// Set once axod has started its Pis (see `registry::Launch`).
    pub(crate) ready: AtomicBool,
    /// Set as axod begins to stop: nothing new starts.
    pub(crate) stopping: AtomicBool,
}

/// What `Core::new` needs that is decided at startup.
pub(crate) struct CoreParts {
    pub(crate) store: Store,
    pub(crate) host_id: String,
    pub(crate) host_generation: String,
    pub(crate) home: PathBuf,
    pub(crate) attach_socket_path: PathBuf,
    pub(crate) agent_socket: PathBuf,
    pub(crate) pi_directories: PiDirectories,
    pub(crate) sessions_directory: PathBuf,
    pub(crate) settings: Settings,
    pub(crate) viewport: Option<Viewport>,
    pub(crate) lifeline: axo_agent::Lifeline,
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Core {
    pub(crate) fn new(parts: CoreParts) -> Self {
        Self {
            store: parts.store,
            events: Events::default(),
            catalog: Catalog::default(),
            registry: crate::sessions::Registry::default(),
            host_id: parts.host_id,
            host_generation: parts.host_generation,
            home: parts.home,
            attach_socket_path: parts.attach_socket_path,
            agent_socket: parts.agent_socket,
            pi_directories: parts.pi_directories,
            sessions_directory: parts.sessions_directory,
            settings: Mutex::new(parts.settings),
            viewport: watch::channel(parts.viewport).0,
            lifeline: parts.lifeline,
            bridges_changed: Arc::new(Notify::new()),
            provenance: Mutex::default(),
            reopening: Mutex::default(),
            workspace_states: WorkspaceStates::default(),
            peers: Peers::default(),
            questions: Arc::default(),
            computer: Arc::default(),
            assets: Arc::default(),
            input_key: OnceLock::new(),
            input_key_store: OnceLock::new(),
            pending_focus: Mutex::default(),
            ready: AtomicBool::new(false),
            stopping: AtomicBool::new(false),
        }
    }

    pub(crate) fn settings(&self) -> Settings {
        lock(&self.settings).clone()
    }

    pub(crate) fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Acquire)
    }

    /// Where this Mac's input key is kept; it is read, or made, on the first input request, so
    /// axod touches the Keychain only then.
    pub(crate) fn keep_input_key_in(
        &self,
        store: Arc<dyn axo_relay::credential::HostCredentialStore>,
    ) {
        let _ = self.input_key_store.set(store);
    }

    /// This Mac's input key (RFD0029), made and kept on first use.
    pub(crate) fn input_key(&self) -> Option<&axo_seal::InputKey> {
        if let Some(key) = self.input_key.get() {
            return Some(key);
        }
        let store = self.input_key_store.get()?;
        let key = match store
            .load(INPUT_KEY_ID)
            .ok()
            .and_then(|bytes| axo_seal::InputKey::from_secret_bytes(&bytes))
        {
            Some(key) => key,
            None => {
                let key = axo_seal::InputKey::generate();
                if let Err(error) = store.store(INPUT_KEY_ID, &key.to_secret_bytes()) {
                    // A key that is not kept would change on restart; clients would refuse it.
                    log::warn!("event=input.key_unsaved error={error}");
                    return None;
                }
                log::info!("event=input.key_created");
                key
            }
        };
        let _ = self.input_key.set(key);
        self.input_key.get()
    }

    /// Clients focus `session_id`: live subscribers at once, and a client that lists Sessions
    /// within a short window, so a much later resync cannot replay a stale focus change.
    pub(crate) fn request_focus(&self, session_id: SessionId) {
        self.events.publish(Event::SessionFocus { session_id });
        *lock(&self.pending_focus) = Some((session_id, Instant::now()));
    }

    pub(crate) fn take_pending_focus(&self) -> Option<SessionId> {
        lock(&self.pending_focus)
            .take()
            .filter(|(_, requested)| requested.elapsed() < PENDING_FOCUS_LIFETIME)
            .map(|(session_id, _)| session_id)
    }

    /// Asks for a form and waits; an accepted form comes with its values.
    pub(crate) fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError> {
        self.questions
            .ask_with(self, session_id, message, asked_by, input, timeout)
    }
}

impl QuestionsHost for Core {
    fn has_session(&self, session: SessionId) -> bool {
        self.catalog.contains(session)
    }

    fn publish(&self, event: Event) {
        self.events.publish(event);
    }

    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        Core::input_key(self)
    }
}

impl ComputerHost for Core {
    fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError> {
        Core::ask_with(self, session_id, message, asked_by, input, timeout)
    }

    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        Core::input_key(self)
    }

    fn agent_socket(&self) -> Option<PathBuf> {
        Some(self.agent_socket.clone())
    }
}
