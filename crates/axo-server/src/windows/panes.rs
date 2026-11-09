use super::*;
use axo_protocol::{Layout, LayoutDirection, LayoutNode, ShellId};

impl Backend {
    pub(super) fn spawn_shell(
        self: &Arc<Self>,
        id: SessionId,
        shell: ShellId,
    ) -> io::Result<Arc<terminal::Terminal>> {
        let cwd = axo_store::session_initial_pwd(&self.database.lock().unwrap(), id)?;
        let output = Arc::downgrade(self);
        let exited = output.clone();
        terminal::Terminal::spawn(
            &cwd,
            shell,
            move |sequence, bytes| {
                if let Some(b) = output.upgrade() {
                    b.publish(Event::TerminalOutput {
                        session_id: id,
                        shell_id: shell,
                        sequence,
                        data: axo_protocol::base64::encode(&bytes),
                    });
                }
            },
            move || {
                if let Some(b) = exited.upgrade() {
                    b.publish(Event::ShellActivity {
                        session_id: id,
                        shell_id: shell,
                        activity: axo_protocol::ShellActivity::Exited,
                    });
                }
            },
        )
    }
    pub(super) fn restore_shells(
        self: &Arc<Self>,
        id: SessionId,
        session: &LiveSession,
    ) -> io::Result<()> {
        let ids = axo_store::coding::terminal_ids(&self.database.lock().unwrap(), id)?;
        for shell in ids {
            if !session
                .runtime
                .lock()
                .unwrap()
                .terminals
                .contains_key(&shell)
            {
                let pty = self.spawn_shell(id, shell)?;
                session.runtime.lock().unwrap().terminals.insert(shell, pty);
            }
        }
        Ok(())
    }
    pub(super) fn create_terminal(
        self: &Arc<Self>,
        id: SessionId,
        fresh: bool,
    ) -> io::Result<Value> {
        let session = self.session(id)?;
        let _operation = session.operation.lock().unwrap();
        self.restore_shells(id, &session)?;
        if !fresh {
            if let Some(t) = session
                .runtime
                .lock()
                .unwrap()
                .terminals
                .values()
                .find(|t| t.is_alive())
            {
                return Ok(t.replay());
            }
        }
        if session.runtime.lock().unwrap().terminals.len() >= 16 {
            return Err(invalid("A session can have at most 16 terminals"));
        }
        let cwd = axo_store::session_initial_pwd(&self.database.lock().unwrap(), id)?;
        let shell = axo_store::insert_terminal_shell(&self.database.lock().unwrap(), id, &cwd)?;
        let pty = match self.spawn_shell(id, shell) {
            Ok(t) => t,
            Err(e) => {
                axo_store::archive_shell(&self.database.lock().unwrap(), shell, "spawn_failed")?;
                return Err(e);
            }
        };
        let replay = pty.replay();
        session.runtime.lock().unwrap().terminals.insert(shell, pty);
        let db = self.database.lock().unwrap();
        let layout = match axo_store::read_session_layout(&db, id)? {
            Some(previous) => Layout::try_from(LayoutNode::Split {
                id: axo_protocol::new_uuid_v4()?,
                direction: LayoutDirection::Right,
                ratio: 0.5,
                first: Box::new(previous.root().clone()),
                second: Box::new(LayoutNode::Pane { shell_id: shell }),
            })
            .map_err(io::Error::other)?,
            None => Layout::single(shell),
        };
        axo_store::write_session_layout(&db, id, &layout)?;
        drop(db);
        self.publish_snapshot(id);
        Ok(replay)
    }
    pub(super) fn set_layout(&self, id: SessionId, layout: LayoutNode) -> io::Result<Value> {
        let s = self.session(id)?;
        let _op = s.operation.lock().unwrap();
        let layout = Layout::try_from(layout).map_err(io::Error::other)?;
        let ids = s
            .runtime
            .lock()
            .unwrap()
            .terminals
            .keys()
            .copied()
            .collect();
        if layout.shell_ids() != &ids {
            return Err(invalid(
                "Layout must contain exactly this session's terminals",
            ));
        }
        axo_store::write_session_layout(&self.database.lock().unwrap(), id, &layout)?;
        self.publish_snapshot(id);
        Ok(json!({"saved":true}))
    }
}
