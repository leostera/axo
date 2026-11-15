//! Cancel-safe GTK delivery of a shared Rust attachment opened off the UI thread.
use axo_pty::attach::{PreparedAttachment, open_snapshot};
use gtk4::glib;
use std::{cell::RefCell, io, path::PathBuf, rc::Rc, sync::mpsc, time::Duration};

/// Dropping the task removes its GTK callback and drops any undelivered descriptors.
/// The worker may finish later; a disconnected receiver makes it close its result.
#[must_use]
pub struct AttachmentTask {
    source: Rc<RefCell<Option<glib::SourceId>>>,
}

impl AttachmentTask {
    pub fn start(
        socket: PathBuf,
        shell: i64,
        deliver: impl FnOnce(io::Result<PreparedAttachment>) + 'static,
    ) -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("axo-attach".into())
            .spawn(move || {
                let _ = sender.send(open_snapshot(&socket, shell));
            })?;
        let source = Rc::new(RefCell::new(None));
        let slot = source.clone();
        let mut deliver = Some(deliver);
        let id = glib::timeout_add_local(Duration::from_millis(20), move || {
            let result = match receiver.try_recv() {
                Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(mpsc::TryRecvError::Disconnected) => {
                    Err(io::Error::other("attachment worker stopped"))
                }
                Ok(result) => result,
            };
            // The source removes itself on Break; its guard must not remove it twice.
            slot.borrow_mut().take();
            if let Some(deliver) = deliver.take() {
                deliver(result);
            }
            glib::ControlFlow::Break
        });
        *source.borrow_mut() = Some(id);
        Ok(Self { source })
    }
}

impl Drop for AttachmentTask {
    fn drop(&mut self) {
        if let Some(source) = self.source.borrow_mut().take() {
            source.remove();
        }
    }
}
