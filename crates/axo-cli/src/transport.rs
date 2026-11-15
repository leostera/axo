//! CLI presentation of the shared local client; no separate wire implementation.
use super::{Failure, output};
use serde_json::Value;
use std::{path::Path, time::Duration};

impl From<axo_client::Error> for Failure {
    fn from(error: axo_client::Error) -> Self {
        let code = match &error {
            axo_client::Error::Input(_) => 2,
            axo_client::Error::Transport(_) => 3,
            axo_client::Error::Rejected { .. } => 4,
        };
        Self {
            code,
            message: error.to_string(),
        }
    }
}

pub(crate) struct Client(axo_client::Client);
impl Client {
    pub(crate) async fn connect(path: &Path) -> Result<Self, Failure> {
        Ok(Self(axo_client::Client::connect(path).await?))
    }
    pub(crate) async fn negotiate(&mut self) -> Result<Value, Failure> {
        Ok(self.0.negotiate().await?)
    }
    pub(crate) async fn call(&mut self, method: &str, params: Value) -> Result<Value, Failure> {
        Ok(self.0.call(method, params).await?)
    }
}

pub(crate) async fn watch(
    path: &Path,
    params: Value,
    timeout: Option<Duration>,
) -> Result<(), Failure> {
    let serve = async {
        let mut stream = axo_client::EventStream::open(path, params).await?;
        output(stream.acknowledgement(), true)?;
        loop {
            let batch = stream.next().await?;
            output(batch.wire(), true)?;
            if batch.lagged() {
                return Err(Failure::transport(
                    "event subscription lagged; relist Sessions and subscribe again",
                ));
            }
        }
    };
    let deadline = async {
        match timeout {
            Some(timeout) => tokio::time::sleep(timeout).await,
            None => std::future::pending::<()>().await,
        }
    };
    tokio::select! {
        result = serve => result,
        _ = deadline => Err(Failure::transport("event watch deadline reached")),
        _ = tokio::signal::ctrl_c() => Err(Failure { code:130, message:"event watch interrupted".into() }),
    }
}
