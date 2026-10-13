//! Owned HTTP model; counts requests without retaining prompt bodies. Tool mode
//! asks vanilla Pi to run real bash and persist its own canonical result.
use serde_json::json;
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};
pub(super) struct Model {
    pub port: u16,
    pub requests: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Model {
    pub fn new() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let count = requests.clone();
        let stopping = stop.clone();
        let worker = thread::spawn(move || {
            let mut peers = Vec::<thread::JoinHandle<()>>::new();
            while !stopping.load(Ordering::SeqCst) {
                let mut index = 0;
                while index < peers.len() {
                    if peers[index].is_finished() {
                        let _ = peers.swap_remove(index).join();
                    } else {
                        index += 1;
                    }
                }
                match listener.accept() {
                    // Idle fetch preconnections must not hold the real request
                    // behind their read deadline. Every handler is owned/bounded.
                    Ok((stream, _)) if peers.len() < 32 => {
                        let count = count.clone();
                        peers.push(thread::spawn(move || {
                            let _ = respond(stream, &count);
                        }));
                    }
                    Ok(_) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10))
                    }
                    Err(_) => break,
                }
            }
            for peer in peers {
                let _ = peer.join();
            }
        });
        Self {
            port,
            requests,
            stop,
            worker: Some(worker),
        }
    }
}
fn respond(mut stream: TcpStream, count: &AtomicUsize) -> std::io::Result<()> {
    // BSD/macOS accepted sockets inherit the listener's nonblocking mode.
    // Read deadlines alone do not make those sockets blocking.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    let invalid = || std::io::Error::other("Invalid owned fixture request");
    let mut bytes = Vec::new();
    let header_end;
    loop {
        let mut chunk = [0; 4096];
        let size = stream.read(&mut chunk)?;
        if size == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&chunk[..size]);
        if bytes.len() > 1_048_576 {
            return Err(invalid());
        }
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            header_end = index + 4;
            break;
        }
    }
    let header = std::str::from_utf8(&bytes[..header_end]).map_err(|_| invalid())?;
    let length = header
        .lines()
        .find_map(|line| {
            line.split_once(':')
                .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        })
        .ok_or_else(invalid)?;
    if length > 1_048_576 {
        return Err(invalid());
    }
    while bytes.len() < header_end + length {
        let mut chunk = [0; 4096];
        let size = stream.read(&mut chunk)?;
        if size == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&chunk[..size]);
    }
    let request: serde_json::Value =
        serde_json::from_slice(&bytes[header_end..header_end + length]).map_err(|_| invalid())?;
    let tool = request["messages"]
        .as_array()
        .and_then(|messages| messages.last())
        .is_some_and(|message| {
            message["role"] == "user"
                && message["content"]
                    .to_string()
                    .contains("Owned central fixture tool request")
        });
    count.fetch_add(1, Ordering::SeqCst);
    let frame = |delta: serde_json::Value, finish: serde_json::Value| {
        json!({"id":"owned","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":delta,"finish_reason":finish}]}).to_string()
    };
    let body = format!(
        "data: {}\n\ndata: {}\n\ndata: {}\n\ndata: [DONE]\n\n",
        frame(json!({"role":"assistant"}), json!(null)),
        frame(
            if tool {
                json!({"tool_calls":[{"index":0,"id":"owned-bash","type":"function","function":{"name":"bash","arguments":json!({"command":"i=0; while [ \"$i\" -lt 3000 ]; do printf 'λ界'; i=$((i+1)); done"}).to_string()}}]})
            } else {
                json!({"content":"Owned central fixture complete"})
            },
            json!(null)
        ),
        frame(json!({}), json!(if tool { "tool_calls" } else { "stop" }))
    );
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes())
}
impl Drop for Model {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
