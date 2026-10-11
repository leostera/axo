//! Owned loopback OpenAI stream fixture. Actual Pi performs execution and persistence.
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};
pub struct Fixture {
    root: PathBuf,
    port: u16,
    requests: Arc<AtomicUsize>,
    stopping: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Fixture {
    pub fn new() -> Self {
        let root = std::env::temp_dir().join(format!("axo-public-pi-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(AtomicUsize::new(0));
        let stopping = Arc::new(AtomicBool::new(false));
        let count = requests.clone();
        let stop = stopping.clone();
        let worker = thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => serve(stream, &count),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            root,
            port,
            requests,
            stopping,
            worker: Some(worker),
        }
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.port)
    }
    pub fn requests(&self) -> usize {
        self.requests.load(Ordering::SeqCst)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn serve(mut stream: TcpStream, requests: &AtomicUsize) {
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut bytes = Vec::new();
    let header_end;
    loop {
        if bytes.len() > 8192 {
            return;
        }
        let mut chunk = [0; 1024];
        let Ok(count) = stream.read(&mut chunk) else {
            return;
        };
        if count == 0 {
            return;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            header_end = index + 4;
            break;
        }
    }
    let Ok(header) = std::str::from_utf8(&bytes[..header_end]) else {
        return;
    };
    let Some(length) = header.lines().find_map(|line| {
        line.split_once(':')
            .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, value)| value.trim().parse::<usize>().ok())
    }) else {
        return;
    };
    if length > 1024 * 1024 {
        return;
    }
    while bytes.len() < header_end + length {
        let mut chunk = [0; 4096];
        let Ok(count) = stream.read(&mut chunk) else {
            return;
        };
        if count == 0 {
            return;
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    let Ok(body) = serde_json::from_slice::<Value>(&bytes[header_end..header_end + length]) else {
        return;
    };
    let count = requests.fetch_add(1, Ordering::SeqCst) + 1;
    let finished = body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| message["role"] == "tool");
    let streamed = body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| {
            message["content"]
                .to_string()
                .contains("BLOCK_PUBLIC_STREAM")
        });
    if streamed && !finished {
        if stream
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
            )
            .is_err()
        {
            return;
        }
        for index in 0..200 {
            let delta = if index == 0 {
                json!({"role":"assistant","content":"stream"})
            } else {
                json!({"content":"."})
            };
            let frame = json!({"id":format!("fixture-{count}"),"object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":delta,"finish_reason":null}]}).to_string();
            if stream
                .write_all(format!("data: {frame}\n\n").as_bytes())
                .is_err()
            {
                return;
            }
            thread::sleep(Duration::from_millis(50));
        }
        let _ = stream.write_all(b"data: [DONE]\n\n");
        return;
    }
    let delta = if finished {
        json!({"content":"Actual public RPC tool complete λ 界"})
    } else if body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| {
            message["content"]
                .to_string()
                .contains("TITLE_AND_ACTUAL_TOOL")
        })
    {
        json!({"tool_calls":[
            {"index":0,"id":format!("bash-{count}"),"type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf Pi-owned-tool > marker.txt\"}"}},
            {"index":1,"id":format!("title-{count}"),"type":"function","function":{"name":"axo_set_title","arguments":"{\"title\":\"Axo Workbench\"}"}}
        ]})
    } else if body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| {
            message["content"]
                .to_string()
                .contains("ASK_OWNED_QUESTION")
        })
    {
        json!({"tool_calls":[{"index":0,"id":format!("call-{count}"),"type":"function","function":{"name":"axo_ask","arguments":"{\"title\":\"Approve fixture?\",\"options\":[\"Allow\",\"Deny\"]}"}}]})
    } else if body["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| message["content"].to_string().contains("CLOUD_ACTUAL_TOOL"))
    {
        json!({"tool_calls":[{"index":0,"id":format!("call-{count}"),"type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf Cloud-owned-tool > cloud-marker.txt\"}"}}]})
    } else {
        json!({"tool_calls":[{"index":0,"id":format!("call-{count}"),"type":"function","function":{"name":"bash","arguments":"{\"command\":\"printf Pi-owned-tool > marker.txt\"}"}}]})
    };
    let frame = |delta: Value, reason: Value| {
        json!({"id":format!("fixture-{count}"),"object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":delta,"finish_reason":reason}]}).to_string()
    };
    let body = format!(
        "data: {}\n\ndata: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
        frame(json!({"role":"assistant"}), Value::Null),
        frame(delta, Value::Null),
        frame(
            json!({}),
            json!(if finished { "stop" } else { "tool_calls" })
        )
    );
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
}
