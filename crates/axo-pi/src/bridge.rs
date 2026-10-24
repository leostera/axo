//! The bridge's wire transport: newline-delimited JSON records over the Pi's Unix socket.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use axo_pty::process;
use serde::Serialize;
use serde::de::DeserializeOwned;

pub const MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Reads one record, blocking up to the stream's read timeout.
pub fn read_record<T: DeserializeOwned>(reader: &mut BufReader<UnixStream>) -> io::Result<T> {
    let mut line = Vec::new();
    let mut limited = reader.take((MAX_RECORD_BYTES + 1) as u64);
    let length = limited.read_until(b'\n', &mut line)?;
    if length == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "Pi bridge closed before completing its response",
        ));
    }
    if length > MAX_RECORD_BYTES || line.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Pi bridge record exceeds its size limit",
        ));
    }
    serde_json::from_slice(&line[..line.len() - 1]).map_err(io::Error::other)
}

// A socket read timeout alone restarts on every byte/event. Recovery must have
// one deadline even when a bridge dribbles bytes or streams unrelated events.
pub fn read_record_until<T: DeserializeOwned>(
    reader: &mut BufReader<UnixStream>,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<T> {
    let mut line = Vec::new();
    loop {
        check_current()?;
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|time| !time.is_zero())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::TimedOut,
                    "Pi bridge recovery request timed out",
                )
            })?;
        reader
            .get_ref()
            .set_read_timeout(Some(remaining.min(POLL_INTERVAL)))?;
        let buffer = match reader.fill_buf() {
            Ok([]) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Pi bridge closed before completing its response",
                ));
            }
            Ok(buffer) => buffer,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                        | io::ErrorKind::Interrupted
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let length = newline.map_or(buffer.len(), |index| index + 1);
        if line.len().saturating_add(length) > MAX_RECORD_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Pi bridge record exceeds its size limit",
            ));
        }
        line.extend_from_slice(&buffer[..length]);
        reader.consume(length);
        if newline.is_some() {
            return serde_json::from_slice(&line[..line.len() - 1]).map_err(io::Error::other);
        }
    }
}

pub fn connect_until(
    path: &Path,
    deadline: Instant,
    check_current: &impl Fn() -> io::Result<()>,
) -> io::Result<UnixStream> {
    // Nonblocking connect matters too: an unresponsive listener with a full
    // accept queue can otherwise pin recovery (or a worker join) in the kernel.
    check_current()?;
    let bytes = path.as_os_str().as_encoded_bytes();
    // SAFETY: sockaddr_un is plain data and zeroing supplies the NUL terminator.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.contains(&0) || bytes.len() >= address.sun_path.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Pi socket path is invalid",
        ));
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = std::mem::size_of_val(&address) as u8;
    }
    for (target, byte) in address.sun_path.iter_mut().zip(bytes) {
        *target = *byte as libc::c_char;
    }
    // SAFETY: socket returns a fresh descriptor, owned immediately below.
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: raw is the newly created descriptor.
    let socket = unsafe { OwnedFd::from_raw_fd(raw) };
    process::set_cloexec(raw)?;
    // SAFETY: these fcntl calls only inspect/update this owned descriptor.
    let flags = unsafe { libc::fcntl(raw, libc::F_GETFL) };
    if flags == -1 || unsafe { libc::fcntl(raw, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: address is initialized and has the specified sockaddr_un length.
    if unsafe {
        libc::connect(
            raw,
            &address as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&address) as libc::socklen_t,
        )
    } == -1
    {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error);
        }
        loop {
            check_current()?;
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .filter(|time| !time.is_zero())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::TimedOut, "Pi bridge connection timed out")
                })?;
            let mut poll = libc::pollfd {
                fd: raw,
                events: libc::POLLOUT,
                revents: 0,
            };
            let timeout = remaining.min(POLL_INTERVAL).as_millis().max(1) as libc::c_int;
            // SAFETY: poll receives one initialized descriptor record.
            let ready = unsafe { libc::poll(&mut poll, 1, timeout) };
            if ready == -1 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                continue;
            }
            let mut error = 0 as libc::c_int;
            let mut length = std::mem::size_of_val(&error) as libc::socklen_t;
            // SAFETY: SO_ERROR writes one int to the correctly sized output.
            if unsafe {
                libc::getsockopt(
                    raw,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    &mut error as *mut _ as *mut libc::c_void,
                    &mut length,
                )
            } == -1
            {
                return Err(io::Error::last_os_error());
            }
            if error != 0 {
                return Err(io::Error::from_raw_os_error(error));
            }
            break;
        }
    }
    check_current()?;
    // SAFETY: restore blocking mode on our connected, still-owned descriptor.
    if unsafe { libc::fcntl(raw, libc::F_SETFL, flags) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(UnixStream::from(socket))
}

pub fn write_record(stream: &mut UnixStream, value: &impl Serialize) -> io::Result<()> {
    let mut encoded = serde_json::to_vec(value).map_err(io::Error::other)?;
    encoded.push(b'\n');
    stream.write_all(&encoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn recovery_connect_is_bounded_when_the_accept_queue_is_full() {
        let directory = crate::test_directory();
        let path = directory.join("full.sock");
        let listener = UnixListener::bind(&path).unwrap();
        // SAFETY: reset the backlog only on this test's owned listener.
        assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
        let mut connections = Vec::new();
        let mut full = false;
        let start = Instant::now();
        for _ in 0..16 {
            match connect_until(
                &path,
                Instant::now() + Duration::from_millis(50),
                &|| Ok(()),
            ) {
                Ok(stream) => connections.push(stream),
                Err(error) => {
                    assert!(
                        matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock
                                | io::ErrorKind::TimedOut
                                | io::ErrorKind::ConnectionRefused
                        ),
                        "unexpected full-backlog error: {error}"
                    );
                    full = true;
                    break;
                }
            }
        }
        assert!(
            !connections.is_empty(),
            "fixture listener never accepted a connection"
        );
        assert!(full, "fixture never filled its bounded accept queue");
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(
            connect_until(&path, Instant::now() + Duration::from_secs(2), &|| Err(
                io::Error::from(io::ErrorKind::Interrupted)
            ))
            .unwrap_err()
            .kind(),
            io::ErrorKind::Interrupted
        );
    }

    #[test]
    fn recovery_deadline_bounds_a_dribbling_partial_record() {
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let producer = thread::spawn(move || {
            for _ in 0..100 {
                if writer.write_all(b" ").is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let mut reader = BufReader::new(reader);
        let start = Instant::now();
        let error = read_record_until::<serde_json::Value>(
            &mut reader,
            start + Duration::from_millis(150),
            &|| Ok(()),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(reader);
        producer.join().unwrap();
    }

    #[test]
    fn recovery_deadline_bounds_a_stream_of_unrelated_events() {
        let (mut writer, reader) = UnixStream::pair().unwrap();
        let producer = thread::spawn(move || {
            for _ in 0..100 {
                if write_record(&mut writer, &json!({ "type": "event" })).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let mut reader = BufReader::new(reader);
        let start = Instant::now();
        let deadline = start + Duration::from_millis(150);
        loop {
            match read_record_until::<serde_json::Value>(&mut reader, deadline, &|| Ok(())) {
                Ok(record) => assert_eq!(record["type"], "event"),
                Err(error) => {
                    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                    break;
                }
            }
        }
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(reader);
        producer.join().unwrap();
    }
}
