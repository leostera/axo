//! Transport-only frontend child. Its TTY is a presentation endpoint, not the work PTY.
use crate::{
    model::*,
    terminal_client::{StreamEvent, TerminalClient},
};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

struct Signals {
    stopping: Arc<AtomicBool>,
    ids: Vec<signal_hook::SigId>,
}
impl Signals {
    fn new() -> io::Result<Self> {
        let mut signals = Self {
            stopping: Arc::new(AtomicBool::new(false)),
            ids: Vec::new(),
        };
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            signals.ids.push(signal_hook::flag::register(
                signal,
                signals.stopping.clone(),
            )?);
        }
        Ok(signals)
    }
}
impl Drop for Signals {
    fn drop(&mut self) {
        for id in self.ids.drain(..) {
            signal_hook::low_level::unregister(id);
        }
    }
}
struct Tty {
    file: File,
    original: libc::termios,
}
impl Tty {
    fn open() -> io::Result<Self> {
        if unsafe { libc::isatty(0) != 1 || libc::isatty(1) != 1 } {
            return Err(io::Error::other(
                "Terminal attachment requires a frontend TTY",
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open("/dev/tty")?;
        let mut original = unsafe { std::mem::zeroed::<libc::termios>() };
        if unsafe { libc::tcgetattr(file.as_raw_fd(), &mut original) } != 0 {
            return Err(io::Error::last_os_error());
        }
        let tty = Self { file, original };
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(tty.file.as_raw_fd(), libc::TCSANOW, &raw) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(tty)
    }
    fn size(&self) -> io::Result<Option<TerminalSize>> {
        let mut size = unsafe { std::mem::zeroed::<libc::winsize>() };
        if unsafe { libc::ioctl(self.file.as_raw_fd(), libc::TIOCGWINSZ, &mut size) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if size.ws_row == 0 || size.ws_col == 0 {
            return Ok(None);
        }
        TerminalSize::new(size.ws_row, size.ws_col)
            .map(Some)
            .map_err(|_| {
                io::Error::other("Frontend terminal geometry exceeds the supported bounds")
            })
    }
    fn write_consumed(&self, data: &[u8]) -> io::Result<()> {
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut remaining = data;
        while !remaining.is_empty() {
            match (&self.file).write(remaining) {
                Ok(0) => return Err(io::Error::other("Frontend terminal output closed")),
                Ok(count) => remaining = &remaining[count..],
                Err(error) if error.kind() == io::ErrorKind::Interrupted => (),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    let timeout = deadline
                        .checked_duration_since(Instant::now())
                        .ok_or_else(|| io::Error::other("Frontend terminal output deadline"))?;
                    let mut fd = libc::pollfd {
                        fd: self.file.as_raw_fd(),
                        events: libc::POLLOUT,
                        revents: 0,
                    };
                    let result =
                        unsafe { libc::poll(&mut fd, 1, timeout.as_millis().max(1) as i32) };
                    if result < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted
                    {
                        return Err(io::Error::last_os_error());
                    }
                    if result == 0
                        || fd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
                    {
                        return Err(io::Error::other("Frontend terminal output unavailable"));
                    }
                }
                Err(error) => return Err(error),
            }
            if Instant::now() >= deadline && !remaining.is_empty() {
                return Err(io::Error::other("Frontend terminal output deadline"));
            }
        }
        Ok(())
    }
    fn input(&self, buffer: &mut [u8]) -> io::Result<Option<usize>> {
        match (&self.file).read(buffer) {
            Ok(count) => Ok(Some(count)),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
}
impl Drop for Tty {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &self.original);
        }
    }
}
struct PendingInput {
    sequence: u64,
    data: Vec<u8>,
}

/// A byte-stream seam only. It refuses truncated replay rather than fabricate a
/// recovered screen. Complete VT/snapshot recovery and native acceptance remain open.
pub fn run(root: &Path, machine: MachineId, runtime: RuntimeRef) -> io::Result<()> {
    let signals = Signals::new()?;
    let tty = Tty::open()?;
    let (mut client, initial) =
        TerminalClient::connect(root, machine, runtime).map_err(io::Error::other)?;
    if initial.truncated {
        return Err(io::Error::other(
            "Terminal screen recovery is unavailable; managed work was left running",
        ));
    }
    tty.write_consumed(initial.backlog.data())?;
    client
        .acknowledge(&initial.backlog)
        .map_err(io::Error::other)?;
    let mut submitted_size = None;
    let mut pending: Option<PendingInput> = None;
    let mut input = [0; 4096];
    while !signals.stopping.load(Ordering::SeqCst) {
        if !client.resize_pending()
            && let Some(size) = tty.size()?
            && submitted_size != Some(size)
        {
            client.resize(size).map_err(io::Error::other)?;
            submitted_size = Some(size);
        }
        match client.read().map_err(io::Error::other)? {
            Some(StreamEvent::Output(chunk)) => {
                tty.write_consumed(chunk.data())?;
                client.acknowledge(&chunk).map_err(io::Error::other)?;
            }
            Some(StreamEvent::InputApplied {
                sequence,
                accepted_bytes,
            }) => {
                let mut original = pending
                    .take()
                    .ok_or_else(|| io::Error::other("Unexpected frontend input receipt"))?;
                if original.sequence != sequence || accepted_bytes > original.data.len() {
                    return Err(io::Error::other("Unexpected frontend input receipt"));
                }
                // Only a specifically acknowledged unaccepted suffix is eligible
                // for a new sequence. No uncertain packet is ever resent.
                original.data.drain(..accepted_bytes);
                if !original.data.is_empty() {
                    original.sequence = client.input(&original.data).map_err(io::Error::other)?;
                    pending = Some(original);
                }
            }
            Some(StreamEvent::Resized { .. }) => (),
            Some(StreamEvent::Exited { .. }) => {
                eprintln!("Terminal presentation ended: DaemonExited");
                return Ok(()); // Not a durable stop/completion receipt.
            }
            None => (),
        }
        if pending.is_none()
            && !client.input_pending()
            && let Some(count) = tty.input(&mut input)?
        {
            if count == 0 {
                eprintln!("Terminal presentation ended: FrontendInputEof");
                return Ok(());
            }
            let sequence = client.input(&input[..count]).map_err(io::Error::other)?;
            pending = Some(PendingInput {
                sequence,
                data: input[..count].to_vec(),
            });
        }
    }
    eprintln!("Terminal presentation ended: FrontendSignal");
    // Drop closes only this presentation lease; no managed PID/group is signaled.
    Ok(())
}
