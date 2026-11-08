//! A daemon-owned Windows pseudoconsole. Closing a view never kills its shell;
//! archiving its session or shutting down axod kills the entire process job.
use super::*;
use std::io::{Read, Write};
use std::os::windows::{
    ffi::OsStrExt,
    io::{AsRawHandle, FromRawHandle, OwnedHandle},
};
use std::sync::atomic::{AtomicBool, Ordering};
use windows_sys::Win32::{
    Foundation::*,
    System::{JobObjects::*, Threading::*},
};
type Handle = *mut std::ffi::c_void;
#[repr(C)]
#[derive(Clone, Copy)]
struct Coord {
    x: i16,
    y: i16,
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreatePipe(
        read: *mut Handle,
        write: *mut Handle,
        attributes: *const std::ffi::c_void,
        size: u32,
    ) -> i32;
    fn CreatePseudoConsole(
        size: Coord,
        input: Handle,
        output: Handle,
        flags: u32,
        console: *mut Handle,
    ) -> i32;
    fn ResizePseudoConsole(console: Handle, size: Coord) -> i32;
    fn ClosePseudoConsole(console: Handle);
}
struct Console(Handle);
unsafe impl Send for Console {}
unsafe impl Sync for Console {}
impl Drop for Console {
    fn drop(&mut self) {
        unsafe {
            ClosePseudoConsole(self.0);
        }
    }
}
#[derive(Default)]
struct Output {
    chunks: VecDeque<(u64, Vec<u8>)>,
    bytes: usize,
    sequence: u64,
}
pub(super) struct Terminal {
    console: Mutex<Option<Console>>,
    process: OwnedHandle,
    job: OwnedHandle,
    input: Mutex<(std::fs::File, u64)>,
    output: Arc<Mutex<Output>>,
    stopped: AtomicBool,
    pub pid: u32,
    pub shell: axo_protocol::ShellId,
}
fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}
fn pipe() -> io::Result<(OwnedHandle, OwnedHandle)> {
    let mut read = std::ptr::null_mut();
    let mut write = std::ptr::null_mut();
    if unsafe { CreatePipe(&mut read, &mut write, std::ptr::null(), 0) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe {
        (
            OwnedHandle::from_raw_handle(read),
            OwnedHandle::from_raw_handle(write),
        )
    })
}
impl Terminal {
    pub fn spawn(
        cwd: &Path,
        shell: axo_protocol::ShellId,
        on_output: impl Fn(u64, Vec<u8>) + Send + 'static,
        on_exit: impl Fn() + Send + 'static,
    ) -> io::Result<Arc<Self>> {
        let (input_read, input_write) = pipe()?;
        let (output_read, output_write) = pipe()?;
        let mut pc = std::ptr::null_mut();
        let code = unsafe {
            CreatePseudoConsole(
                Coord { x: 100, y: 30 },
                input_read.as_raw_handle(),
                output_write.as_raw_handle(),
                0,
                &mut pc,
            )
        };
        if code != 0 {
            return Err(io::Error::other(format!(
                "CreatePseudoConsole failed: {code:#x}"
            )));
        }
        let console = Console(pc);
        drop(input_read);
        drop(output_write);
        let mut size = 0;
        unsafe {
            InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size);
        }
        let mut storage = vec![0_usize; size.div_ceil(std::mem::size_of::<usize>())];
        let attributes = storage.as_mut_ptr().cast();
        if unsafe { InitializeProcThreadAttributeList(attributes, 1, 0, &mut size) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let created = (|| -> io::Result<_> {
            unsafe {
                if UpdateProcThreadAttribute(
                    attributes,
                    0,
                    0x00020016,
                    pc,
                    std::mem::size_of::<Handle>(),
                    std::ptr::null_mut(),
                    std::ptr::null(),
                ) == 0
                {
                    return Err(io::Error::last_os_error());
                }
                let mut startup: STARTUPINFOEXW = std::mem::zeroed();
                startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
                // Otherwise Windows can duplicate the daemon's redirected stdio into
                // the shell even with handle inheritance disabled, bypassing ConPTY.
                // Null handles with STARTF_USESTDHANDLES make Windows attach new console
                // handles instead: microsoft/terminal discussion #15814.
                startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                startup.lpAttributeList = attributes;
                let executable = PathBuf::from(
                    std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()),
                )
                .join("System32/WindowsPowerShell/v1.0/powershell.exe");
                let app = wide(executable.as_os_str());
                let mut command = wide(std::ffi::OsStr::new(&format!(
                    "\"{}\" -NoLogo -NoProfile -NoExit",
                    executable.display()
                )));
                // A developer parent (notably pwsh/Codex) can inject its own PSModulePath.
                // Let Windows PowerShell build its own native module search path. Never
                // change execution policy or answer a publisher trust prompt on the user's behalf.
                let mut environment = std::env::vars_os()
                    .filter(|(key, _)| {
                        ![
                            "PSModulePath",
                            "TERM",
                            "COLORTERM",
                            "TERM_PROGRAM",
                            "COLUMNS",
                            "LINES",
                        ]
                        .iter()
                        .any(|name| key.eq_ignore_ascii_case(std::ffi::OsStr::new(name)))
                    })
                    .collect::<Vec<_>>();
                environment.extend([
                    ("TERM".into(), "xterm-256color".into()),
                    ("COLORTERM".into(), "truecolor".into()),
                    ("TERM_PROGRAM".into(), "Axo".into()),
                ]);
                environment.sort_by_key(|(key, _)| key.to_string_lossy().to_uppercase());
                let mut environment = environment
                    .into_iter()
                    .flat_map(|(key, value)| {
                        let mut text = key.encode_wide().collect::<Vec<_>>();
                        text.push(b'=' as u16);
                        text.extend(value.encode_wide());
                        text.push(0);
                        text
                    })
                    .collect::<Vec<_>>();
                environment.push(0);
                let directory = wide(cwd.as_os_str());
                let mut process: PROCESS_INFORMATION = std::mem::zeroed();
                if CreateProcessW(
                    app.as_ptr(),
                    command.as_mut_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    0,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
                    environment.as_ptr().cast(),
                    directory.as_ptr(),
                    &startup.StartupInfo,
                    &mut process,
                ) == 0
                {
                    return Err(io::Error::last_os_error());
                }
                let handle = OwnedHandle::from_raw_handle(process.hProcess);
                let thread = OwnedHandle::from_raw_handle(process.hThread);
                let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if job.is_null() {
                    TerminateProcess(handle.as_raw_handle(), 1);
                    return Err(io::Error::last_os_error());
                }
                let job = OwnedHandle::from_raw_handle(job);
                let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                if SetInformationJobObject(
                    job.as_raw_handle(),
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    std::mem::size_of_val(&limits) as u32,
                ) == 0
                    || AssignProcessToJobObject(job.as_raw_handle(), handle.as_raw_handle()) == 0
                {
                    TerminateProcess(handle.as_raw_handle(), 1);
                    return Err(io::Error::last_os_error());
                }
                if ResumeThread(thread.as_raw_handle()) == u32::MAX {
                    TerminateJobObject(job.as_raw_handle(), 1);
                    return Err(io::Error::last_os_error());
                }
                Ok((handle, job, process.dwProcessId))
            }
        })();
        unsafe {
            DeleteProcThreadAttributeList(attributes);
        }
        let (process, job, pid) = created?;
        let output = Arc::new(Mutex::new(Output::default()));
        let history = output.clone();
        let mut reader = std::fs::File::from(output_read);
        std::thread::Builder::new()
            .name(format!("axo-conpty-{}", shell))
            .spawn(move || {
                let mut buffer = [0_u8; 8192];
                loop {
                    match reader.read(&mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let chunk = buffer[..n].to_vec();
                            let sequence = {
                                let mut h = history.lock().unwrap();
                                let seq = h.sequence;
                                h.sequence += 1;
                                h.bytes += n;
                                h.chunks.push_back((seq, chunk.clone()));
                                while h.bytes > 2 * 1024 * 1024 {
                                    if let Some((_, old)) = h.chunks.pop_front() {
                                        h.bytes -= old.len();
                                    }
                                }
                                seq
                            };
                            on_output(sequence, chunk);
                        }
                    }
                }
                on_exit();
            })?;
        Ok(Arc::new(Self {
            console: Mutex::new(Some(console)),
            process,
            job,
            input: Mutex::new((std::fs::File::from(input_write), 0)),
            output,
            stopped: AtomicBool::new(false),
            pid,
            shell,
        }))
    }
    pub fn is_alive(&self) -> bool {
        !self.stopped.load(Ordering::Relaxed)
            && unsafe { WaitForSingleObject(self.process.as_raw_handle(), 0) } == WAIT_TIMEOUT
    }
    pub fn write(&self, sequence: u64, data: &[u8]) -> io::Result<()> {
        if !self.is_alive() {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "Terminal exited"));
        }
        let mut input = self.input.lock().unwrap();
        if sequence < input.1 {
            return Ok(());
        }
        if sequence != input.1 {
            return Err(invalid("Terminal input sequence gap"));
        }
        input.0.write_all(data)?;
        input.0.flush()?;
        input.1 += 1;
        Ok(())
    }
    pub fn resize(&self, rows: u32, columns: u32) -> io::Result<()> {
        if !(1..=500).contains(&rows) || !(1..=1000).contains(&columns) {
            return Err(invalid("Terminal dimensions out of bounds"));
        }
        let console = self.console.lock().unwrap();
        let console = console
            .as_ref()
            .ok_or_else(|| io::Error::other("Terminal closed"))?;
        let code = unsafe {
            ResizePseudoConsole(
                console.0,
                Coord {
                    x: columns as i16,
                    y: rows as i16,
                },
            )
        };
        if code == 0 {
            Ok(())
        } else {
            Err(io::Error::other(format!(
                "ResizePseudoConsole failed: {code:#x}"
            )))
        }
    }
    pub fn replay(&self) -> Value {
        let h = self.output.lock().unwrap();
        let input = self.input.lock().unwrap().1;
        json!({"shellId":self.shell,"processId":self.pid,"alive":self.is_alive(),"nextInputSequence":input,"nextOutputSequence":h.sequence,
            "truncated":h.chunks.front().is_some_and(|(n,_)| *n>0),"chunks":h.chunks.iter().map(|(sequence,bytes)| json!({"sequence":sequence,"data":axo_protocol::base64::encode(bytes)})).collect::<Vec<_>>()})
    }
    pub fn stop(&self) {
        if !self.stopped.swap(true, Ordering::SeqCst) {
            unsafe {
                TerminateJobObject(self.job.as_raw_handle(), 0);
                WaitForSingleObject(self.process.as_raw_handle(), 2000);
            }
            self.console.lock().unwrap().take();
        }
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        self.stop();
    }
}
