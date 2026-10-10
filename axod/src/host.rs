//! Read-only local host diagnostics. Cloud online means an acknowledged, unexpired lease.
use crate::{
    model::{HostGeneration, MachineId},
    rpc::{Destination, Outcome},
    runtime::Manager,
};
use serde::{Deserialize, Serialize};
use std::{
    io,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    " (",
    env!("AXOD_BUILD_REVISION"),
    ")"
);
#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CloudStatus {
    NotConfigured,
    Connecting,
    Offline,
    Online {
        #[serde(rename = "leaseId")]
        lease_id: uuid::Uuid,
        #[serde(rename = "expiresAt")]
        expires_at: u64,
    },
}
struct CloudObservation {
    status: CloudStatus,
    deadline: Option<Instant>,
}
pub struct HostStatus {
    cloud: Mutex<CloudObservation>,
}
impl Default for HostStatus {
    fn default() -> Self {
        Self {
            cloud: Mutex::new(CloudObservation {
                status: CloudStatus::NotConfigured,
                deadline: None,
            }),
        }
    }
}
impl HostStatus {
    pub fn connecting(&self) {
        self.set(CloudStatus::Connecting, None);
    }
    pub fn offline(&self) {
        self.set(CloudStatus::Offline, None);
    }
    pub fn acknowledge(&self, lease_id: uuid::Uuid, expires_at: u64) -> io::Result<()> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| io::Error::other("Invalid cloud clock"))?
            .as_millis() as u64;
        let remaining = expires_at
            .checked_sub(now)
            .filter(|value| *value > 0 && *value <= 30_000)
            .ok_or_else(|| io::Error::other("Invalid cloud lease deadline"))?;
        self.set(
            CloudStatus::Online {
                lease_id,
                expires_at,
            },
            Some(Instant::now() + Duration::from_millis(remaining)),
        );
        Ok(())
    }
    fn set(&self, status: CloudStatus, deadline: Option<Instant>) {
        *self.cloud.lock().unwrap() = CloudObservation { status, deadline };
    }
    fn current(&self) -> CloudStatus {
        let cloud = self.cloud.lock().unwrap();
        if cloud
            .deadline
            .is_some_and(|deadline| deadline <= Instant::now())
        {
            CloudStatus::Offline
        } else {
            cloud.status.clone()
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct HostResult {
    host_generation: HostGeneration,
    machine_id: MachineId,
    hostname: String,
    machine_type: String,
    daemon_version: &'static str,
    cloud: CloudStatus,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GetHostRequest {
    target: Destination,
}
pub(crate) fn get(
    params: Option<serde_json::Value>,
    manager: &Manager,
    machine: MachineId,
) -> Outcome {
    let request: GetHostRequest = serde_json::from_value(params.unwrap_or(serde_json::Value::Null))
        .map_err(|_| (-32602, "Invalid params"))?;
    crate::rpc::validate_target(
        request.target.machine_id,
        request.target.host_generation,
        manager,
        machine,
    )?;
    let (hostname, machine_type) = identity();
    serde_json::to_value(HostResult {
        host_generation: manager.generation,
        machine_id: machine,
        hostname: hostname.clone(),
        machine_type: machine_type.clone(),
        daemon_version: VERSION,
        cloud: manager.host.current(),
    })
    .map_err(|_| (-32009, "Host diagnostics unavailable"))
}
pub(crate) fn identity() -> &'static (String, String) {
    static IDENTITY: OnceLock<(String, String)> = OnceLock::new();
    IDENTITY.get_or_init(|| {
        let mut buffer = [0u8; 256];
        let hostname =
            if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0 {
                std::str::from_utf8(
                    &buffer[..buffer
                        .iter()
                        .position(|byte| *byte == 0)
                        .unwrap_or(buffer.len())],
                )
                .ok()
                .map(str::to_owned)
            } else {
                None
            };
        (
            bounded_name(hostname, "Mac"),
            bounded_name(machine_type(), "Mac"),
        )
    })
}
fn bounded_name(value: Option<String>, fallback: &str) -> String {
    value
        .filter(|value| {
            !value.is_empty()
                && value.encode_utf16().count() <= 80
                && !value.chars().any(char::is_control)
        })
        .unwrap_or_else(|| fallback.to_owned())
}
#[cfg(target_os = "macos")]
fn machine_type() -> Option<String> {
    use std::{
        io::Read,
        process::{Command, Stdio},
        thread,
    };
    // Only public model name is retained. Never print the hardware document (which includes serials).
    let mut child = Command::new("/usr/sbin/system_profiler")
        .args(["-json", "-detailLevel", "mini", "SPHardwareDataType"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    use std::os::fd::AsRawFd;
    let mut stdout = child.stdout.take()?;
    let flags = unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_GETFL) };
    if flags < 0
        || unsafe { libc::fcntl(stdout.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
    {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut exit = None;
    let deadline = Instant::now() + Duration::from_secs(3);
    let success = loop {
        let mut eof = false;
        let failed_read = match stdout.read(&mut buffer) {
            Ok(0) => {
                eof = true;
                false
            }
            Ok(count) if bytes.len() + count <= 64 * 1024 => {
                bytes.extend_from_slice(&buffer[..count]);
                false
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => false,
            _ => true,
        };
        if exit.is_none() {
            exit = child.try_wait().ok().flatten();
        }
        if let Some(status) = exit
            && eof
        {
            break status.success();
        }
        if failed_read || Instant::now() >= deadline {
            // Never signal a child after try_wait has reaped it.
            if exit.is_none() {
                let _ = child.kill();
                let _ = child.wait();
            }
            break false;
        }
        thread::sleep(Duration::from_millis(10));
    };
    if !success {
        return None;
    }
    #[derive(Deserialize)]
    struct Hardware {
        machine_name: String,
    }
    #[derive(Deserialize)]
    struct Document {
        #[serde(rename = "SPHardwareDataType")]
        hardware: Vec<Hardware>,
    }
    serde_json::from_slice::<Document>(&bytes)
        .ok()?
        .hardware
        .into_iter()
        .next()
        .map(|hardware| hardware.machine_name)
}
#[cfg(not(target_os = "macos"))]
fn machine_type() -> Option<String> {
    Some(std::env::consts::OS.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn online_requires_bounded_acknowledged_deadline() {
        let host = HostStatus::default();
        assert!(matches!(host.current(), CloudStatus::NotConfigured));
        host.connecting();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        assert!(host.acknowledge(uuid::Uuid::new_v4(), now).is_err());
        assert!(
            host.acknowledge(uuid::Uuid::new_v4(), now + 60_000)
                .is_err()
        );
        host.acknowledge(uuid::Uuid::new_v4(), now + 5000).unwrap();
        assert!(matches!(host.current(), CloudStatus::Online { .. }));
        host.cloud.lock().unwrap().deadline = Some(Instant::now() - Duration::from_secs(1));
        assert!(matches!(host.current(), CloudStatus::Offline));
    }
}
