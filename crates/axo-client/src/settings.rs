//! Settings stay daemon-owned, including command parsing, ranges and persistence.
use crate::{Client, Error};
use axo_protocol::{ConfigKey, rpc};
use serde_json::json;

impl Client {
    pub async fn config_value(&mut self, key: ConfigKey) -> Result<rpc::ConfigValue, Error> {
        let response = self
            .call_typed(rpc::method::CONFIG_GET, json!({"key":key}))
            .await?;
        self.match_config_key(key, response)
    }

    /// One write, never retried. A lost reply may mean the value was saved;
    /// callers must reload before offering a retry. The daemon parses the value.
    pub async fn set_config_value(
        &mut self,
        key: ConfigKey,
        value: &str,
    ) -> Result<rpc::ConfigValue, Error> {
        let response = self
            .call_typed(rpc::method::CONFIG_SET, json!({"key":key,"value":value}))
            .await?;
        self.match_config_key(key, response)
    }

    fn match_config_key(
        &mut self,
        key: ConfigKey,
        response: rpc::ConfigValue,
    ) -> Result<rpc::ConfigValue, Error> {
        if response.key != key {
            self.stream.take();
            return Err(Error::Transport(
                "daemon returned a different setting; reload before retrying writes".into(),
            ));
        }
        Ok(response)
    }
}
