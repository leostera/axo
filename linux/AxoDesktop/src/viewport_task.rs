//! Native main-loop adapter for the shared serial viewport reporter. No socket I/O on GTK.
use axo_client::{ViewportReporter, ViewportStatus};
use axo_protocol::Viewport;
use gtk4::glib;
use std::{cell::RefCell, io, path::PathBuf, rc::Rc, time::Duration};

pub struct ViewportTask {
    reporter: Rc<RefCell<Option<ViewportReporter>>>,
    source: Rc<RefCell<Option<glib::SourceId>>>,
}
impl ViewportTask {
    pub fn start(
        socket: PathBuf,
        mut deliver: impl FnMut(Result<ViewportStatus, String>) + 'static,
    ) -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let (reporter, worker) = ViewportReporter::channel();
        std::thread::Builder::new()
            .name("axo-viewport".into())
            .spawn(move || runtime.block_on(worker.run(&socket)))?;
        let reporter = Rc::new(RefCell::new(Some(reporter)));
        let source = Rc::new(RefCell::new(None));
        let receiver = reporter.clone();
        let slot = source.clone();
        let id = glib::timeout_add_local(Duration::from_millis(50), move || {
            let status = receiver
                .borrow_mut()
                .as_mut()
                .map(|reporter| reporter.take_status());
            match status {
                Some(Ok(Some(status))) => deliver(Ok(status)),
                Some(Ok(None)) => {}
                Some(Err(error)) => {
                    slot.borrow_mut().take();
                    receiver.borrow_mut().take();
                    deliver(Err(error.to_string()));
                    return glib::ControlFlow::Break;
                }
                None => return glib::ControlFlow::Break,
            }
            glib::ControlFlow::Continue
        });
        *source.borrow_mut() = Some(id);
        Ok(Self { reporter, source })
    }
    pub fn report(&self, epoch: u64, viewport: Viewport) {
        if let Some(reporter) = self.reporter.borrow().as_ref() {
            let _ = reporter.report(epoch, viewport);
        }
    }
    pub fn suspend(&self) {
        if let Some(reporter) = self.reporter.borrow().as_ref() {
            reporter.suspend();
        }
    }
    pub fn retry(&self) -> bool {
        self.reporter
            .borrow()
            .as_ref()
            .is_some_and(|reporter| reporter.retry().is_ok())
    }
}
impl Drop for ViewportTask {
    fn drop(&mut self) {
        if let Some(source) = self.source.borrow_mut().take() {
            source.remove();
        }
        self.reporter.borrow_mut().take();
    }
}
