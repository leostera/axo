//! One bounded worker result delivered on GTK's thread; dropping cancels delivery.
use gtk4::glib;
use std::{cell::RefCell, io, rc::Rc, sync::mpsc, time::Duration};

#[must_use]
pub struct MainThreadTask {
    source: Rc<RefCell<Option<glib::SourceId>>>,
}
impl MainThreadTask {
    pub fn start<T: Send + 'static>(
        name: &str,
        work: impl FnOnce() -> io::Result<T> + Send + 'static,
        deliver: impl FnOnce(io::Result<T>) + 'static,
    ) -> io::Result<Self> {
        let (sender, receiver) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name(name.into())
            .spawn(move || {
                let _ = sender.send(work());
            })?;
        let source = Rc::new(RefCell::new(None));
        let slot = source.clone();
        let mut deliver = Some(deliver);
        let id = glib::timeout_add_local(Duration::from_millis(20), move || {
            let result = match receiver.try_recv() {
                Err(mpsc::TryRecvError::Empty) => return glib::ControlFlow::Continue,
                Err(mpsc::TryRecvError::Disconnected) => {
                    Err(io::Error::other("background worker stopped"))
                }
                Ok(result) => result,
            };
            // Break removes the source; the guard must not remove it twice.
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
impl Drop for MainThreadTask {
    fn drop(&mut self) {
        if let Some(source) = self.source.borrow_mut().take() {
            source.remove();
        }
    }
}
