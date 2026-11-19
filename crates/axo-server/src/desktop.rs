//! Linux pane-controller identity comes from a retained daemon child, never caller claims.
use std::io;
use std::path::Path;
use std::process::Stdio;
use std::sync::Mutex;

use axo_agent::process::ProcessIdentity;
use axo_protocol::rpc::DesktopOpened;
use tokio::process::{Child, Command};

#[derive(Default)]
pub(crate) struct Desktop {
    running: Mutex<Option<Running>>,
}
struct Running {
    child: Child,
    identity: ProcessIdentity,
}
impl Desktop {
    /// Launch only the bundled workbench, with daemon-owned arguments and resources.
    pub(crate) fn open(&self, socket: &Path) -> io::Result<DesktopOpened> {
        let executable = std::env::current_exe()?;
        let root = executable
            .parent()
            .ok_or_else(|| io::Error::other("runtime directory unavailable"))?;
        let program = root.join("AxoDesktop");
        let mut command = Command::new(program);
        command
            .arg("--socket")
            .arg(socket)
            .env("GHOSTTY_RESOURCES_DIR", root.join("share/ghostty"))
            .env("LD_LIBRARY_PATH", root.join("lib"))
            .env_remove("LD_PRELOAD")
            .env_remove("LD_AUDIT")
            .env_remove("AXO_SESSION_ID")
            .env_remove("AXO_PANE_ID")
            .env_remove("AXO_SHELL_ID")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        self.open_command(command)
    }
    #[cfg(test)]
    pub(crate) fn open_test_program(&self, command: Command) -> io::Result<DesktopOpened> {
        self.open_command(command)
    }
    fn open_command(&self, mut command: Command) -> io::Result<DesktopOpened> {
        let mut running = crate::core::lock(&self.running);
        if let Some(existing) = running.as_mut() {
            match existing.child.try_wait() {
                Ok(None) => {
                    return Ok(DesktopOpened {
                        process_id: existing.identity.pid,
                    });
                }
                Ok(Some(_)) => {}
                Err(error) => {
                    running.take();
                    return Err(error);
                }
            }
            running.take();
        }
        command.kill_on_drop(true);
        let child = command.spawn()?;
        let identity = child
            .id()
            .and_then(ProcessIdentity::of)
            .ok_or_else(|| io::Error::other("desktop process identity unavailable"))?;
        // The child remains owned and unreaped until this slot is retired under the same lock.
        *running = Some(Running { child, identity });
        log::info!("event=desktop.started process_id={}", identity.pid);
        Ok(DesktopOpened {
            process_id: identity.pid,
        })
    }
    pub(crate) fn owns(&self, caller: ProcessIdentity) -> bool {
        let mut running = crate::core::lock(&self.running);
        let Some(instance) = running.as_mut() else {
            return false;
        };
        if !matches!(instance.child.try_wait(), Ok(None)) {
            running.take();
            return false;
        }
        caller == instance.identity && caller.parent() == ProcessIdentity::of(std::process::id())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sleeper() -> Command {
        let mut command = Command::new("/bin/sleep");
        command.arg("30");
        command
    }
    #[tokio::test]
    async fn only_the_retained_live_child_has_pane_authority() {
        let desktop = Desktop::default();
        let opened = desktop.open_command(sleeper()).unwrap();
        let identity = ProcessIdentity::of(opened.process_id).unwrap();
        assert!(desktop.owns(identity));
        assert!(!desktop.owns(ProcessIdentity::of(std::process::id()).unwrap()));
        let mut lookalike = sleeper().kill_on_drop(true).spawn().unwrap();
        assert!(!desktop.owns(ProcessIdentity::of(lookalike.id().unwrap()).unwrap()));
        assert_eq!(
            desktop.open_command(sleeper()).unwrap().process_id,
            opened.process_id
        );
        lookalike.kill().await.unwrap();
        {
            let mut running = crate::core::lock(&desktop.running);
            let child = &mut running.as_mut().unwrap().child;
            child.start_kill().unwrap();
        }
        for _ in 0..100 {
            if !desktop.owns(identity) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(!desktop.owns(identity));
        let next = desktop.open_command(sleeper()).unwrap();
        assert_ne!(next.process_id, opened.process_id);
        assert!(
            !desktop.owns(identity),
            "a retired instance cannot reclaim the new desktop's role"
        );
        assert!(desktop.owns(ProcessIdentity::of(next.process_id).unwrap()));
    }
    #[tokio::test]
    async fn a_failed_launch_registers_nobody() {
        let desktop = Desktop::default();
        assert!(
            desktop
                .open_command(Command::new("/nonexistent/owned-fixture/AxoDesktop"))
                .is_err()
        );
        assert!(crate::core::lock(&desktop.running).is_none());
    }
}
