//! Peak thread count, open descriptors and resident memory of the daemon, sampled via
//! `proc_pidinfo` while probes run.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

const SAMPLE_INTERVAL: Duration = Duration::from_millis(200);

#[derive(Clone, Copy, Debug, Default)]
pub struct ProcessPeak {
    pub threads: u32,
    pub descriptors: u32,
    pub resident_bytes: u64,
}

pub struct Sampler {
    stop: Arc<AtomicBool>,
    thread: thread::JoinHandle<ProcessPeak>,
}

impl Sampler {
    pub fn start(pid: i32) -> Sampler {
        let stop = Arc::new(AtomicBool::new(false));
        let thread = thread::spawn({
            let stop = Arc::clone(&stop);
            move || {
                let mut peak = ProcessPeak::default();
                while !stop.load(Ordering::Relaxed) {
                    if let Some(sample) = sample(pid) {
                        peak.threads = peak.threads.max(sample.threads);
                        peak.descriptors = peak.descriptors.max(sample.descriptors);
                        peak.resident_bytes = peak.resident_bytes.max(sample.resident_bytes);
                    }
                    thread::sleep(SAMPLE_INTERVAL);
                }
                peak
            }
        });
        Sampler { stop, thread }
    }

    pub fn finish(self) -> ProcessPeak {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.join().unwrap_or_default()
    }
}

fn sample(pid: i32) -> Option<ProcessPeak> {
    let mut task: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as i32;
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size) };
    if read != size {
        return None;
    }
    // With a null buffer, PROC_PIDLISTFDS returns the bytes needed for the descriptor list.
    let bytes =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
    let descriptors = (bytes.max(0) as usize / std::mem::size_of::<libc::proc_fdinfo>()) as u32;
    Some(ProcessPeak {
        threads: task.pti_threadnum as u32,
        descriptors,
        resident_bytes: task.pti_resident_size,
    })
}
