//! What a Pi is doing, from its bridge events.

use axo_protocol::SessionStatus;

#[derive(Clone, Copy, Debug, Default)]
pub struct Activity {
    pub connected: bool,
    pub working: bool,
    pub ui_waits: u16,
}

impl Activity {
    pub fn status(self) -> SessionStatus {
        if !self.connected {
            SessionStatus::Unavailable
        } else if self.ui_waits > 0 {
            SessionStatus::NeedsAttention
        } else if self.working {
            SessionStatus::Working
        } else {
            SessionStatus::Ready
        }
    }
}
