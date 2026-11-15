//! Attachments are prepared off the GTK thread; the task owns delivery/lifetime.
use crate::task::MainThreadTask;
use axo_pty::attach::{PreparedAttachment, open_snapshot};
use std::{io, path::PathBuf};

#[must_use]
pub struct AttachmentTask {
    _task: MainThreadTask,
}
impl AttachmentTask {
    pub fn start(
        socket: PathBuf,
        shell: i64,
        deliver: impl FnOnce(io::Result<PreparedAttachment>) + 'static,
    ) -> io::Result<Self> {
        Ok(Self {
            _task: MainThreadTask::start(
                "axo-attach",
                move || open_snapshot(&socket, shell),
                deliver,
            )?,
        })
    }
}
