//! The Session manager as the computer-use extension's host (`axo-computer-use`, RFD0028):
//! asking the person, this Mac's input key, and axod's socket for the gate. Also the account's
//! assets slot, which the relay fills.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use axo_computer_use::{ComputerHost, ComputerUse};
use axo_protocol::SessionId;
use axo_protocol::elicitation::{Asker, ElicitationOutcome, InputRequest};
use axo_questions::Values;
use axo_relay::assets::AssetSource;
use axo_relay::computer::ComputerParams;
use jsonrpc_core::Error as RpcError;
use serde_json::Value;

use super::SessionManager;

impl ComputerHost for SessionManager {
    fn ask_with(
        &self,
        session_id: SessionId,
        message: &str,
        asked_by: Asker,
        input: Option<InputRequest>,
        timeout: Duration,
    ) -> Result<(ElicitationOutcome, Option<Values>), RpcError> {
        SessionManager::ask_with(self, session_id, message, asked_by, input, timeout)
    }

    fn input_key(&self) -> Option<&axo_seal::InputKey> {
        SessionManager::input_key(self)
    }

    fn agent_socket(&self) -> Option<PathBuf> {
        super::spawn::agent_socket().map(PathBuf::from)
    }
}

impl SessionManager {
    /// Computer use here, for the computer-use extension.
    pub(crate) fn computer(&self) -> Arc<ComputerUse> {
        Arc::clone(&self.computer)
    }

    /// One computer-use tool for another Mac's script. `Err` fails the script's call.
    pub(crate) fn remote_computer(&self, request: &ComputerParams) -> Result<Value, (i64, String)> {
        self.computer.remote(self, request)
    }

    /// Whether this Mac can do computer use now.
    pub(crate) fn computer_status(&self) -> Value {
        ComputerUse::status()
    }

    pub(crate) fn set_asset_source(&self, source: Option<AssetSource>) {
        self.asset_source.set(source);
    }

    /// The slot the relay fills with the account's assets, for the assets extension.
    pub(crate) fn asset_slot(&self) -> Arc<axo_assets::AssetSlot> {
        Arc::clone(&self.asset_source)
    }
}
