//! One open Session as a task (RFD0041): it owns its panes, its Pi and the Pi's bridge link, and
//! the prompts waiting for that Pi. Everything that changes a Session is a message to its task,
//! handled one at a time, so nothing about a Session needs a lock. What the Session looks like is
//! published to the catalog, which anyone reads without asking the task.
//!
//! Nothing slow runs inside the task: a Pi launch runs on the blocking pool and reports back, a
//! command for Pi is sent on its link by whoever asked, and waiting for a Pi to come up is a wait
//! on the catalog.

pub(crate) mod controls;
pub(crate) mod panes;
pub(crate) mod pi;
pub(crate) mod prompts;
pub(crate) mod record;

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::future::Future;
use std::io;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use axo_agent::pi::link::LinkEvent;
use axo_protocol::rpc;
use axo_protocol::{
    Event, Layout, PaneRole, SessionId, SessionRecord, ShellActivity, ShellId, ShellRecord,
};
use axo_pty::process;
use axo_pty::{TerminalOutput, WindowSize};
use axo_store::{Connection, StoredSession, StoredSessionRow};
use tokio::sync::mpsc;

use self::panes::{Running, RuntimeId, spawn_shell, stop_in_background, window_size};
use self::pi::Pi;
pub(crate) use self::pi::{Launched, PiStart, Waiter};
use crate::catalog::{Entry, PiPhase};
use crate::core::Core;
use crate::terminal_input::TerminalInput;

/// What a Session's task is asked to do.
pub(crate) enum Message {
    /// Run this on the Session, in turn.
    Job(Job),
    /// A pane's process exited.
    PaneExited {
        shell_id: ShellId,
        runtime_id: RuntimeId,
    },
    /// The Pi's link said something.
    Link {
        runtime_id: RuntimeId,
        event: LinkEvent,
    },
    /// A Pi launch ended.
    Launched {
        attempt: u64,
        result: io::Result<Launched>,
    },
    /// A Pi asked to exit did not in time.
    KillPi { runtime_id: RuntimeId },
}

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
pub(crate) type Job = Box<dyn for<'a> FnOnce(&'a mut Session) -> BoxFuture<'a, ()> + Send>;

fn gone() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "session is not open")
}

/// How the rest of axod reaches a Session's task. Cheap to clone.
#[derive(Clone)]
pub(crate) struct SessionHandle {
    pub(crate) id: SessionId,
    mailbox: mpsc::UnboundedSender<Message>,
}

impl SessionHandle {
    /// Runs `job` on the Session, in turn, and returns what it returns.
    pub(crate) async fn call<R, F>(&self, job: F) -> io::Result<R>
    where
        R: Send + 'static,
        F: for<'a> FnOnce(&'a mut Session) -> BoxFuture<'a, R> + Send + 'static,
    {
        let (reply, answer) = tokio::sync::oneshot::channel();
        self.mailbox
            .send(Message::Job(Box::new(move |session| {
                Box::pin(async move {
                    let _ = reply.send(job(session).await);
                })
            })))
            .map_err(|_| gone())?;
        answer.await.map_err(|_| gone())
    }

    /// [`Self::call`] for work that does not wait.
    pub(crate) async fn with<R, F>(&self, job: F) -> io::Result<R>
    where
        R: Send + 'static,
        F: FnOnce(&mut Session) -> R + Send + 'static,
    {
        self.call(move |session| {
            let result = job(session);
            Box::pin(async move { result })
        })
        .await
    }

    /// Asks the Session to do something without waiting for it.
    pub(crate) fn post(&self, job: impl FnOnce(&mut Session) + Send + 'static) {
        let _ = self.mailbox.send(Message::Job(Box::new(move |session| {
            job(session);
            Box::pin(async {})
        })));
    }
}

/// One open Session's state, owned by its task.
pub(crate) struct Session {
    pub(crate) core: Arc<Core>,
    pub(crate) id: SessionId,
    /// Set as the Session closes: its catalog entry is never written again.
    closed: Arc<AtomicBool>,
    mailbox: mpsc::WeakUnboundedSender<Message>,
    /// What the store holds of it, as of its last write.
    row: StoredSessionRow,
    /// Every pane whose process runs.
    panes: BTreeMap<ShellId, Running>,
    /// Its Pi pane, running or not.
    pi: Option<Pi>,
    /// The task ends after this message.
    ended: bool,
    /// Nothing is published until its first Pi launch ends: a new Session appears with its Pi.
    quiet: bool,
}

/// Opens `stored` as a Session: its terminals start now; its Pi starts as `pi` says. With a
/// `waiter`, the Session appears only once its Pi has started (or failed to), and `waiter` hears
/// which.
pub(crate) async fn open(
    core: &Arc<Core>,
    stored: StoredSession,
    pi: PiStart,
    waiter: Option<Waiter>,
) -> io::Result<SessionHandle> {
    let id = stored.id;
    let row = core
        .store
        .call(move |database| axo_store::open_session_row(database, id))
        .await?;
    let (sender, mailbox) = mpsc::unbounded_channel();
    let handle = SessionHandle {
        id,
        mailbox: sender.clone(),
    };
    let mut session = Session {
        core: Arc::clone(core),
        id,
        closed: Arc::new(AtomicBool::new(false)),
        mailbox: sender.downgrade(),
        row,
        panes: BTreeMap::new(),
        pi: None,
        ended: false,
        quiet: waiter.is_some(),
    };
    core.registry.insert(handle.clone());
    session.restore(stored, pi, waiter).await;
    tokio::spawn(run(session, mailbox));
    Ok(handle)
}

async fn run(mut session: Session, mut mailbox: mpsc::UnboundedReceiver<Message>) {
    if session.ended {
        return;
    }
    while let Some(message) = mailbox.recv().await {
        session.handle(message).await;
        if session.ended {
            break;
        }
    }
}

fn not_open(what: &str) -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, format!("{what} is not open"))
}

impl Session {
    async fn handle(&mut self, message: Message) {
        match message {
            Message::Job(job) => job(self).await,
            Message::PaneExited {
                shell_id,
                runtime_id,
            } => self.pane_exited(shell_id, runtime_id).await,
            Message::Link { runtime_id, event } => self.link_event(runtime_id, event).await,
            Message::Launched { attempt, result } => self.launched(attempt, result).await,
            Message::KillPi { runtime_id } => self.kill_pi(runtime_id),
        }
    }

    /// Posts a message to this Session's own task, for when something it started reports.
    fn mailbox(&self) -> mpsc::WeakUnboundedSender<Message> {
        self.mailbox.clone()
    }

    /// Starts the stored panes: terminals now, Pi as `pi` says. A terminal that cannot start
    /// (its folder was deleted, say) is archived as if its shell had exited; a Session left with
    /// no pane is archived.
    async fn restore(&mut self, stored: StoredSession, pi: PiStart, waiter: Option<Waiter>) {
        let mut failed = Vec::new();
        for (shell_id, role, pane_id) in &stored.shell_ids {
            match role {
                PaneRole::Terminal => {
                    let size = self.pane_size(*shell_id);
                    let settings = self.core.settings();
                    match spawn_shell(&settings.shell_command, &stored.initial_pwd, size) {
                        Ok(running) => self.install(*shell_id, running),
                        Err(error) => {
                            log::warn!(
                                "event=session.shell_restore_failed session_id={} shell_id={} error_kind={:?} reason={error}",
                                self.id,
                                shell_id.get(),
                                error.kind()
                            );
                            failed.push(*shell_id);
                        }
                    }
                }
                PaneRole::Pi => match pane_id {
                    Some(pane_id) => {
                        self.pi = Some(Pi::new(*shell_id, pane_id.clone()));
                    }
                    None => {
                        log::warn!(
                            "event=session.pi_pane_invalid session_id={} reason=missing_pane_id",
                            self.id
                        );
                        failed.push(*shell_id);
                    }
                },
            }
        }
        if !failed.is_empty() {
            let remaining: HashSet<ShellId> = self.open_shell_ids().into_iter().collect();
            if remaining.is_empty() {
                self.close("shell_restore_failed").await;
                return;
            }
            for shell_id in failed {
                let remaining = remaining.clone();
                let id = self.id;
                if let Err(error) = self
                    .write(move |database| {
                        axo_store::archive_shell_and_prune_layout(
                            database,
                            shell_id,
                            id,
                            "shell_restore_failed",
                            &remaining,
                        )
                    })
                    .await
                {
                    log::warn!("event=session.archive_failed session_id={id} reason={error}");
                }
            }
        }
        self.publish();
        self.start_pi_as(pi, waiter).await;
    }

    /// A process enters the Session: its output is published, and its exit is told to the task.
    fn install(&mut self, shell_id: ShellId, running: Running) {
        let mailbox = self.mailbox();
        let runtime_id = running.runtime_id;
        running.bind(&self.core, self.id, shell_id, move || {
            if let Some(mailbox) = mailbox.upgrade() {
                let _ = mailbox.send(Message::PaneExited {
                    shell_id,
                    runtime_id,
                });
            }
        });
        if let Some(replaced) = self.panes.insert(shell_id, running) {
            stop_in_background(vec![replaced]);
        }
    }

    /// Every open pane, running or not.
    pub(crate) fn open_shell_ids(&self) -> BTreeSet<ShellId> {
        let mut ids: BTreeSet<ShellId> = self.panes.keys().copied().collect();
        ids.extend(self.pi.as_ref().map(|pi| pi.shell_id));
        ids
    }

    /// Runs a write on the store, then reads the Session's row back.
    async fn write<R: Send + 'static>(
        &mut self,
        write: impl FnOnce(&mut Connection) -> io::Result<R> + Send + 'static,
    ) -> io::Result<R> {
        let id = self.id;
        let (result, row) = self
            .core
            .store
            .call(move |database| {
                let result = write(database)?;
                Ok((result, axo_store::open_session_row(database, id)?))
            })
            .await?;
        self.row = row;
        Ok(result)
    }

    /// The layout clients show: the stored one, or the open panes side by side.
    fn effective_layout(&self) -> Option<Layout> {
        self.row
            .layout
            .clone()
            .or_else(|| record::default_layout(self.open_shell_ids().into_iter().collect()))
    }

    /// The size a pane should start at: its place in the layout, or the whole terminal area for
    /// a pane the layout does not have yet.
    fn pane_size(&self, shell_id: ShellId) -> WindowSize {
        let Some(viewport) = *self.core.viewport.borrow() else {
            return WindowSize::DEFAULT;
        };
        let placed = self.effective_layout().and_then(|layout| {
            viewport
                .grid_sizes(layout.root())
                .into_iter()
                .find(|(id, _)| *id == shell_id)
        });
        window_size(placed.map_or_else(|| viewport.full_grid(), |(_, grid)| grid))
    }

    /// Sizes the panes no client is attached to from the viewport. Attached panes are sized by
    /// their client, so the two never contend for one PTY.
    pub(crate) fn fit_unattached_panes(&self) {
        let (Some(viewport), Some(layout)) =
            (*self.core.viewport.borrow(), self.effective_layout())
        else {
            return;
        };
        for (shell_id, grid) in viewport.grid_sizes(layout.root()) {
            let Some(running) = self
                .panes
                .get(&shell_id)
                .filter(|running| running.attachments == 0)
            else {
                continue;
            };
            let size = window_size(grid);
            if let Err(error) = process::resize_if_changed(&running.master, &running.child, size) {
                log::warn!(
                    "event=pane.fit_failed session_id={} shell_id={} error_kind={:?}",
                    self.id,
                    shell_id.get(),
                    error.kind()
                );
            }
        }
    }

    /// How clients see the Session now.
    pub(crate) fn record(&self) -> SessionRecord {
        let attach = &self.core.attach_socket_path;
        let mut shells: Vec<ShellRecord> = self
            .panes
            .iter()
            .map(|(shell_id, running)| running.record(*shell_id, attach))
            .collect();
        if let Some(pi) = &self.pi
            && !self.panes.contains_key(&pi.shell_id)
        {
            shells.push(record::idle_pi_record(
                pi.shell_id,
                Some(pi.pane_id.clone()),
                self.row.folder.clone(),
                pi.is_dormant(),
                attach,
            ));
        }
        shells.sort_by_key(|shell| shell.id.get());
        let status = record::status(&shells, self.pi.as_ref().and_then(Pi::status));
        let row = &self.row;
        SessionRecord {
            id: self.id,
            pi_session_file: row.pi_session_file.clone(),
            pi_session_id: row.pi_session_id.clone(),
            name: row.name.clone(),
            manual_name: row.manual_name.clone(),
            emoji: row.emoji.clone(),
            last_message_at: row.last_message_at.or_else(|| {
                row.pi_session_file
                    .as_deref()
                    .and_then(record::file_modification_timestamp)
            }),
            created_at: row.created_at,
            status,
            folder: row.folder.clone(),
            shells,
            layout: row.layout.clone(),
            pi: self.pi.as_ref().and_then(|pi| pi.controls.runtime.clone()),
        }
    }

    /// Writes the Session's catalog entry and tells clients.
    pub(crate) fn publish(&self) {
        if self.ended || self.quiet {
            return;
        }
        let record = self.record();
        let (phase, working) = self
            .pi
            .as_ref()
            .map_or((PiPhase::Absent, false), |pi| (pi.phase(), pi.working()));
        self.core.catalog.put(
            Entry {
                record: record.clone(),
                pi: phase,
                working,
            },
            &self.closed,
        );
        self.core.events.publish(Event::snapshot(record));
    }

    fn shell_activity(&self, shell_id: ShellId, activity: ShellActivity) {
        self.core.events.publish(Event::ShellActivity {
            session_id: self.id,
            shell_id,
            activity,
        });
    }

    /// Archives the Session, stops its panes, and ends its task.
    pub(crate) async fn close(&mut self, reason: &'static str) {
        if self.ended {
            return;
        }
        let id = self.id;
        if let Err(error) = self
            .core
            .store
            .call(move |database| axo_store::archive_session(database, id, reason))
            .await
        {
            log::warn!("event=session.archive_failed session_id={id} reason={error}");
        }
        let announced = !self.quiet;
        self.end();
        log::info!("event=session.closed session_id={id} reason={reason}");
        if announced {
            self.core
                .events
                .publish(Event::SessionRemoved { session_id: id });
        }
    }

    /// Leaves the catalog and stops every pane, without touching the store.
    fn end(&mut self) {
        self.ended = true;
        self.closed.store(true, Ordering::Release);
        self.core.catalog.remove(self.id);
        self.core.registry.remove(self.id);
        crate::core::lock(&self.core.provenance).forget(self.id);
        if let Some(pi) = &mut self.pi {
            pi.let_go();
        }
        stop_in_background(std::mem::take(&mut self.panes).into_values().collect());
    }

    /// Stops every pane and waits for them, as axod stops.
    pub(crate) async fn shut_down(&mut self) {
        self.ended = true;
        self.closed.store(true, Ordering::Release);
        if let Some(pi) = &mut self.pi {
            pi.let_go();
        }
        let mut stopping = tokio::task::JoinSet::new();
        for (_, running) in std::mem::take(&mut self.panes) {
            stopping.spawn(running.stop());
        }
        while stopping.join_next().await.is_some() {}
    }

    async fn pane_exited(&mut self, shell_id: ShellId, runtime_id: RuntimeId) {
        if self
            .panes
            .get(&shell_id)
            .is_none_or(|running| running.runtime_id != runtime_id)
        {
            return;
        }
        let Some(mut running) = self.panes.remove(&shell_id) else {
            return;
        };
        match running.child.try_wait() {
            Ok(status) => log::info!(
                "event=session.child_exited session_id={} shell_id={} runtime_id={runtime_id} pid={} status={status:?}",
                self.id,
                shell_id.get(),
                running.child.id()
            ),
            Err(error) => log::warn!(
                "event=session.child_wait_failed session_id={} shell_id={} error_kind={:?}",
                self.id,
                shell_id.get(),
                error.kind()
            ),
        }
        stop_in_background(vec![running]);
        self.shell_activity(shell_id, ShellActivity::Exited);
        if self.pi.as_ref().is_some_and(|pi| pi.shell_id == shell_id) {
            self.pi_exited().await;
            return;
        }
        let remaining: HashSet<ShellId> = self.open_shell_ids().into_iter().collect();
        if remaining.is_empty() {
            self.close("shell_exited").await;
            return;
        }
        let id = self.id;
        if let Err(error) = self
            .write(move |database| {
                axo_store::archive_shell_and_prune_layout(
                    database,
                    shell_id,
                    id,
                    "shell_exited",
                    &remaining,
                )
            })
            .await
        {
            log::warn!("event=session.archive_failed session_id={id} reason={error}");
        }
        self.publish();
    }

    pub(crate) async fn create_shell(&mut self) -> io::Result<ShellRecord> {
        let folder = self.row.folder.clone();
        let id = self.id;
        let shell_id = self
            .write(move |database| axo_store::insert_terminal_shell(database, id, &folder))
            .await?;
        let size = self.pane_size(shell_id);
        let settings = self.core.settings();
        let running = match spawn_shell(&settings.shell_command, &self.row.folder, size) {
            Ok(running) => running,
            Err(error) => {
                let _ = self
                    .write(move |database| {
                        axo_store::archive_shell(database, shell_id, "spawn_failed")
                    })
                    .await;
                return Err(error);
            }
        };
        let record = running.record(shell_id, &self.core.attach_socket_path);
        self.install(shell_id, running);
        self.publish();
        self.shell_activity(shell_id, ShellActivity::Started);
        Ok(record)
    }

    /// Closes a pane; closing its Pi or its last pane closes the Session.
    pub(crate) async fn close_shell(&mut self, shell_id: ShellId) -> io::Result<rpc::ShellClosed> {
        let open = self.open_shell_ids();
        if !open.contains(&shell_id) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "shell is not open in this session",
            ));
        }
        let is_pi = self.pi.as_ref().is_some_and(|pi| pi.shell_id == shell_id);
        if is_pi || open.len() == 1 {
            self.close("explicit_close").await;
            self.shell_activity(shell_id, ShellActivity::Exited);
            return Ok(rpc::ShellClosed {
                archived_shell_id: shell_id,
                archived_session_id: Some(self.id),
            });
        }
        let remaining: HashSet<ShellId> = open.into_iter().filter(|id| *id != shell_id).collect();
        let id = self.id;
        self.write(move |database| {
            axo_store::archive_shell_and_prune_layout(
                database,
                shell_id,
                id,
                // Not `explicit_close`, which marks the panes that closed with their Session and
                // so come back when it is reopened.
                "pane_closed",
                &remaining,
            )
        })
        .await?;
        stop_in_background(self.panes.remove(&shell_id).into_iter().collect());
        self.publish();
        self.shell_activity(shell_id, ShellActivity::Exited);
        Ok(rpc::ShellClosed {
            archived_shell_id: shell_id,
            archived_session_id: None,
        })
    }

    pub(crate) async fn set_layout(&mut self, layout: Layout) -> io::Result<()> {
        let open: HashSet<ShellId> = self.open_shell_ids().into_iter().collect();
        if *layout.shell_ids() != open {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "layout does not match the session's open shells",
            ));
        }
        let id = self.id;
        self.write(move |database| axo_store::write_session_layout(database, id, &layout))
            .await?;
        self.fit_unattached_panes();
        self.publish();
        Ok(())
    }

    pub(crate) async fn rename(&mut self, name: String) -> io::Result<SessionRecord> {
        if !record::valid_session_title(&name) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Session name must be between 1 and 80 characters",
            ));
        }
        let id = self.id;
        self.write(move |database| axo_store::set_manual_session_name(database, id, &name))
            .await?;
        self.publish();
        Ok(self.record())
    }

    fn running(&self, shell_id: ShellId) -> io::Result<&Running> {
        self.panes.get(&shell_id).ok_or_else(|| not_open("shell"))
    }

    pub(crate) fn input(&self, shell_id: ShellId) -> io::Result<Arc<TerminalInput>> {
        self.running(shell_id)
            .map(|running| Arc::clone(&running.input))
    }

    pub(crate) fn output(&self, shell_id: ShellId) -> io::Result<Arc<TerminalOutput>> {
        self.running(shell_id)
            .map(|running| Arc::clone(&running.output))
    }

    pub(crate) fn resize(&self, shell_id: ShellId, size: WindowSize) -> io::Result<()> {
        let running = self.running(shell_id)?;
        process::resize(&running.master, &running.child, size)
    }

    /// Whether closing the pane would stop something: a Pi in a turn, or a shell running a
    /// program in the foreground.
    pub(crate) fn busy(&self, shell_id: ShellId) -> io::Result<rpc::ShellBusy> {
        let running = self.running(shell_id)?;
        if running.role == PaneRole::Pi {
            return Ok(rpc::ShellBusy {
                busy: self.pi.as_ref().is_some_and(Pi::working),
                foreground_process: None,
            });
        }
        // SAFETY: the PTY master descriptor stays open while the shell is running.
        let foreground = unsafe { libc::tcgetpgrp(running.master.as_raw_fd()) };
        if foreground == -1 {
            return Err(io::Error::last_os_error());
        }
        if foreground == running.child.id() as libc::pid_t {
            return Ok(rpc::ShellBusy {
                busy: false,
                foreground_process: None,
            });
        }
        Ok(rpc::ShellBusy {
            busy: true,
            foreground_process: process_name(foreground),
        })
    }

    /// One more attachment to a pane: a copy of its PTY master, its output, and whether it is
    /// the first.
    pub(crate) fn attach(&mut self, shell_id: ShellId) -> io::Result<crate::attachments::Attached> {
        let running = self
            .panes
            .get_mut(&shell_id)
            .ok_or_else(|| not_open("shell"))?;
        let master = running.duplicate_master()?;
        running.attachments += 1;
        let attached = crate::attachments::Attached {
            master,
            output: Arc::clone(&running.output),
            session_id: self.id,
            runtime_id: running.runtime_id,
        };
        if running.attachments == 1 {
            self.shell_activity(shell_id, ShellActivity::Attached);
        }
        Ok(attached)
    }

    pub(crate) fn detached(&mut self, shell_id: ShellId, runtime_id: RuntimeId) {
        let Some(running) = self.panes.get_mut(&shell_id) else {
            return;
        };
        if running.runtime_id != runtime_id {
            return;
        }
        running.attachments = running.attachments.saturating_sub(1);
        if running.attachments == 0 {
            self.shell_activity(shell_id, ShellActivity::Detached);
        }
    }

    /// The Session's folder, as stored.
    pub(crate) fn folder(&self) -> PathBuf {
        self.row.folder.clone()
    }

    /// A pane's PTY size, as (rows, columns).
    #[cfg(test)]
    pub(crate) fn pty_size(&self, shell_id: ShellId) -> io::Result<(u16, u16)> {
        let size = process::window_size(&self.running(shell_id)?.master)?;
        Ok((size.rows(), size.columns()))
    }

    /// The PTY master's close-on-exec flag and device, for checking a pane's PTY.
    #[cfg(test)]
    pub(crate) fn pty(&self, shell_id: ShellId) -> io::Result<(bool, String)> {
        let running = self.running(shell_id)?;
        // SAFETY: reads the flags of a descriptor the pane owns.
        let flags = unsafe { libc::fcntl(running.master.as_raw_fd(), libc::F_GETFD) };
        Ok((flags & libc::FD_CLOEXEC != 0, running.device.clone()))
    }

    /// How many clients are attached to a pane.
    #[cfg(test)]
    pub(crate) fn attachments(&self, shell_id: ShellId) -> io::Result<usize> {
        Ok(self.running(shell_id)?.attachments)
    }
}

#[cfg(target_vendor = "apple")]
fn process_name(process_id: libc::pid_t) -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is writable for its full length; proc_name NUL-terminates within it.
    let length =
        unsafe { libc::proc_name(process_id, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    let name = String::from_utf8_lossy(&buffer[..length as usize]).into_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_vendor = "apple"))]
fn process_name(_process_id: libc::pid_t) -> Option<String> {
    None
}
