//! One durable presentation for desktop history and relay sync. Codex owns the native
//! activity; the existing message ledger owns prompt receipts and streamed reply identity.
use super::*;
use axo_agent::transcript::{PiHeader, pi_lines, with_activity, write_if_changed};

#[derive(PartialEq, Eq)]
struct NativeStamp {
    path: PathBuf,
    bytes: u64,
    modified: std::time::SystemTime,
}

#[derive(PartialEq, Eq)]
pub(super) struct Fingerprint {
    presentation: String,
    native: Option<NativeStamp>,
}

fn native_stamp(source: Option<&Path>) -> io::Result<Option<NativeStamp>> {
    let Some(path) = source else { return Ok(None) };
    match std::fs::metadata(path) {
        Ok(metadata) => Ok(Some(NativeStamp {
            path: path.to_owned(),
            bytes: metadata.len(),
            modified: metadata.modified()?,
        })),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

impl Backend {
    pub(super) fn remember_conversation(&self, id: SessionId, result: &Value) -> io::Result<()> {
        if let Some(path) = result["thread"]["path"].as_str() {
            axo_store::coding::set_conversation_path(
                &self.database.lock().unwrap(),
                id,
                Path::new(path),
            )?;
        }
        Ok(())
    }

    pub(super) fn locate_conversation(&self, id: SessionId) -> io::Result<()> {
        let path = axo_store::coding::conversation_path(&self.database.lock().unwrap(), id)?;
        if path.is_some_and(|path| path.is_file()) {
            return Ok(());
        }
        let session = self.session(id)?;
        let agent = session.runtime.lock().unwrap().agent.clone();
        let thread = axo_store::coding::thread_id(&self.database.lock().unwrap(), id)?;
        if let (Some(agent), Some(thread)) = (agent, thread) {
            let reply = agent.request(
                "thread/read",
                json!({"threadId":thread,"includeTurns":false}),
            )?;
            self.remember_conversation(id, &reply)?;
        }
        Ok(())
    }

    pub(super) fn write_transcript(&self, id: SessionId) -> io::Result<PathBuf> {
        // Desktop reads and relay rounds must not race the same atomic replacement.
        let mut cache = self.transcripts.lock().unwrap();
        let (presentation, source, header) = self.text_presentation(id)?;
        let fingerprint = Fingerprint {
            presentation: presentation.clone(),
            native: native_stamp(source.as_deref())?,
        };
        let directory = self.directory.join("codex-transcripts");
        let path = directory.join(format!("{id}.jsonl"));
        // An idle desktop poll must not repeatedly parse the entire native conversation.
        if cache.get(&id) == Some(&fingerprint) && path.is_file() {
            return Ok(path);
        }
        let lines = match source {
            Some(source) => match std::fs::read_to_string(source) {
                Ok(native) => {
                    let converted = pi_lines(axo_agent::AgentKind::Codex, &native, &header)?;
                    with_activity(&presentation, &converted)?
                }
                // Codex may create this later or move an archived rollout. Never truncate
                // previously synced activity merely because the native path is unavailable.
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    match std::fs::read_to_string(&path) {
                        Ok(previous) => with_activity(&presentation, &previous)?,
                        Err(error) if error.kind() == io::ErrorKind::NotFound => presentation,
                        Err(error) => return Err(error),
                    }
                }
                Err(error) => return Err(error),
            },
            None => presentation,
        };
        std::fs::create_dir_all(&directory)?;
        write_if_changed(&path, &lines)?;
        cache.insert(id, fingerprint);
        Ok(path)
    }

    fn text_presentation(&self, id: SessionId) -> io::Result<(String, Option<PathBuf>, PiHeader)> {
        let db = self.database.lock().unwrap();
        let row = axo_store::coding::catalog(&db)?
            .into_iter()
            .find(|row| row["id"] == id.to_string())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Session is missing"))?;
        let header = PiHeader {
            session_id: id.to_string(),
            timestamp: axo_relay::utc_timestamp(row["createdAt"].as_i64().unwrap_or(0) * 1000),
            cwd: row["folder"].as_str().unwrap_or_default().into(),
        };
        // Keep the existing header byte-for-byte, including its agent hint.
        let mut lines = vec![
            json!({"type":"session","version":3,"id":id,
            "timestamp":header.timestamp,"cwd":header.cwd,"agent":"codex"})
            .to_string(),
        ];
        let mut cursor = 0;
        let mut parent = Value::Null;
        loop {
            let messages = axo_store::coding::messages(&db, id, cursor)?;
            for message in &messages {
                cursor = message["sequence"].as_i64().unwrap_or(cursor);
                let at = message["timestampMs"].as_i64().unwrap_or(0);
                if message["role"] == "user" {
                    if let Some(command) = message["commandId"].as_str() {
                        let receipt = format!("axo:command:{cursor}");
                        lines.push(json!({"type":"custom","customType":"axo.command","id":receipt,
                            "parentId":parent,"timestamp":axo_relay::utc_timestamp(at),"data":{"commandId":command}}).to_string());
                        parent = json!(receipt);
                    }
                }
                lines.push(
                    json!({"type":"message","id":message["itemId"],"parentId":parent,
                    "timestamp":axo_relay::utc_timestamp(at),"message":{"role":message["role"],
                    "content":[{"type":"text","text":message["text"]}],"timestamp":at}})
                    .to_string(),
                );
                parent = message["itemId"].clone();
            }
            if messages.len() < 200 {
                break;
            }
        }
        Ok((
            lines.join("\n") + "\n",
            axo_store::coding::conversation_path(&db, id)?,
            header,
        ))
    }
}
