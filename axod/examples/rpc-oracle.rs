//! Development-only differential oracle. Exercises production codec/read admission, never executes work.
use axod::{journal::Journal, model::*, rpc, runtime::Manager};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::{self, BufRead, Read, Write},
    path::PathBuf,
};

#[derive(Deserialize)]
#[serde(tag = "mode", deny_unknown_fields)]
enum Query {
    #[serde(rename = "decode")]
    Decode { raw: String },
    #[serde(rename = "params")]
    Params { method: String, raw: String },
}
fn codec(raw: &str) -> Value {
    match rpc::decode(raw) {
        Err(error) => json!({"error":error["error"]["code"]}),
        Ok(message) => {
            json!({"batch":message.batch,"entries":message.entries.into_iter().map(|entry| match entry {
            Err(error) => json!({"error":error["error"]["code"]}),
            Ok(call) => json!({"method":call.method,"idPresent":call.id.is_some(),"id":call.id.unwrap_or(Value::Null),"params":call.params}),
        }).collect::<Vec<_>>()})
        }
    }
}
fn params(method: String, raw: &str, manager: &Manager, machine: MachineId) -> Value {
    // An oracle input cannot reach either mutation dispatcher, even if test generators regress.
    if method != "axo.runtime.list" {
        return json!({"error":"Oracle read policy"});
    }
    let value: Value = match serde_json::from_str(raw) {
        Ok(value) => value,
        Err(_) => return json!({"valid":false}),
    };
    let call =
        rpc::parse_call(json!({"jsonrpc":"2.0","id":"oracle","method":method,"params":value}))
            .expect("Synthetic read envelope");
    let reply =
        rpc::dispatch(call, manager, machine, &BTreeMap::new()).expect("Response-bearing read");
    json!({"valid":reply["error"]["code"] != -32602})
}
fn main() -> io::Result<()> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or_else(|| io::Error::other("Owned fixture root required"))?,
    );
    let manager = Manager::new(Journal::open(&root)?);
    let machine = MachineId::new();
    let mut out = io::BufWriter::new(io::stdout().lock());
    writeln!(
        out,
        "{}",
        json!({"target":{"machineId":machine,"hostGeneration":manager.generation}})
    )?;
    out.flush()?;
    let mut input = io::BufReader::new(io::stdin().lock());
    loop {
        let mut bytes = Vec::new();
        let count = Read::by_ref(&mut input)
            .take(1_048_577)
            .read_until(b'\n', &mut bytes)?;
        if count == 0 {
            break;
        }
        if count > 1_048_576 || !bytes.ends_with(b"\n") {
            return Err(io::Error::other("Oracle framing limit"));
        }
        let query: Query =
            serde_json::from_slice(&bytes).map_err(|_| io::Error::other("Invalid oracle query"))?;
        let result = match query {
            Query::Decode { raw } => codec(&raw),
            Query::Params { method, raw } => params(method, &raw, &manager, machine),
        };
        writeln!(out, "{result}")?;
        out.flush()?;
    }
    Ok(())
}
