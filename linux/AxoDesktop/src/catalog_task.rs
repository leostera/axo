//! GTK delivery adapter for the shared read-only catalog watcher. No transport policy here.
use axo_client::{CatalogState, CatalogWatch};
use gtk4::glib;
use std::{cell::RefCell, io, path::PathBuf, rc::Rc, sync::Arc, time::Duration};

pub struct CatalogTask {
    watch: Rc<RefCell<Option<CatalogWatch>>>,
    source: Rc<RefCell<Option<glib::SourceId>>>,
}
impl CatalogTask {
    pub fn start(
        socket: PathBuf,
        mut deliver: impl FnMut(Result<Arc<CatalogState>, String>) + 'static,
    ) -> io::Result<Self> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let (watch, watcher) = CatalogWatch::channel();
        std::thread::Builder::new()
            .name("axo-catalog-watch".into())
            .spawn(move || {
                runtime.block_on(watcher.run(&socket));
            })?;
        let watch = Rc::new(RefCell::new(Some(watch)));
        let source = Rc::new(RefCell::new(None));
        let receiver = watch.clone();
        let slot = source.clone();
        let id = glib::timeout_add_local(Duration::from_millis(50), move || {
            // Release the borrow before delivery can close the window/drop this task.
            let update = receiver
                .borrow_mut()
                .as_mut()
                .map(|watch| watch.take_update());
            match update {
                Some(Ok(Some(state))) => deliver(Ok(state)),
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
        Ok(Self { watch, source })
    }
    pub fn refresh(&self) -> bool {
        self.watch
            .borrow()
            .as_ref()
            .is_some_and(|watch| watch.refresh().is_ok())
    }
}
impl Drop for CatalogTask {
    fn drop(&mut self) {
        if let Some(source) = self.source.borrow_mut().take() {
            source.remove();
        }
        self.watch.borrow_mut().take(); // Cancels the worker, not the daemon or its children.
    }
}
