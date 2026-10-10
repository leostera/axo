//! Thin native public RPC caller. Parameters are stdin, never prompt bodies in argv.
use axod::{client::Client, rpc::FRAME_BYTES};
use serde_json::Value;
use std::{
    io::{self, Read, Write},
    path::PathBuf,
};
fn run() -> Result<Value, Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some("rpc") {
        return Err(
            "Usage: axo rpc /absolute/private/local-endpoint.json METHOD < params.json".into(),
        );
    }
    let discovery = PathBuf::from(args.next().ok_or("Missing private discovery")?);
    let method = args.next().ok_or("Missing method")?;
    if args.next().is_some() {
        return Err("Unexpected argument".into());
    }
    let mut raw = Vec::new();
    io::stdin()
        .lock()
        .take((FRAME_BYTES + 1) as u64)
        .read_to_end(&mut raw)
        .map_err(|_| "Cannot read bounded request parameters")?;
    if raw.len() > FRAME_BYTES {
        return Err("Request parameter limit".into());
    }
    let params: Value = serde_json::from_slice(&raw).map_err(|_| "Invalid request parameters")?;
    // Discovery is connection information only. Explicit caller destinations are never rewritten.
    Ok(Client::connect(&discovery)?.call(&method, params)?)
}
fn main() {
    match run() {
        Ok(result) => {
            let mut output = io::stdout().lock();
            if serde_json::to_writer(&mut output, &result).is_err()
                || output.write_all(b"\n").is_err()
            {
                eprintln!("Cannot deliver result; reconcile commandId, do not replay");
                std::process::exit(2);
            }
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
