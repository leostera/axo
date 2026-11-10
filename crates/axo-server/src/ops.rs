//! What a client may do to a Session, shared by local methods and the account's (`remote`):
//! each finds the Session's task and asks it, then does any slow part outside it.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use axo_protocol::commands::StopTarget;
use axo_protocol::rpc::{self, TerminalBytes, TerminalText};
use axo_protocol::{
    Layout, PiCommandInfo, PiModelInfo, SessionId, SessionRecord, ShellId, ShellRecord,
    ThinkingLevel,
};
use axo_pty::WindowSize;
use axo_relay::PiKey;
use tokio::sync::oneshot;

use crate::core::Core;
use crate::session::prompts;
use crate::session::{self as session_task};
use crate::sessions::{self, handle};
use crate::terminal_input::TerminalInput;

pub(crate) const TERMINAL_INPUT_WRITE_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a restart of an unavailable Pi waits for it to start.
const RESTART_WAIT: Duration = Duration::from_secs(30);

pub(crate) async fn rename(core: &Core, id: SessionId, name: String) -> io::Result<SessionRecord> {
    handle(core, id)?
        .call(move |session| Box::pin(session.rename(name)))
        .await?
}

pub(crate) async fn create_shell(core: &Core, id: SessionId) -> io::Result<ShellRecord> {
    handle(core, id)?
        .call(|session| Box::pin(session.create_shell()))
        .await?
}

pub(crate) async fn close_shell(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
) -> io::Result<rpc::ShellClosed> {
    handle(core, id)?
        .call(move |session| Box::pin(session.close_shell(shell_id)))
        .await?
}

pub(crate) async fn set_layout(core: &Core, id: SessionId, layout: Layout) -> io::Result<()> {
    handle(core, id)?
        .call(move |session| Box::pin(session.set_layout(layout)))
        .await?
}

/// The input of a pane: one of this Mac's Sessions', or a remote pane.
async fn input(core: &Core, id: SessionId, shell_id: ShellId) -> io::Result<Arc<TerminalInput>> {
    if let Some(input) = core.peers.input(id, shell_id) {
        return Ok(input);
    }
    handle(core, id)?
        .with(move |session| session.input(shell_id))
        .await?
}

/// Runs a blocking write to a pane on the blocking pool.
async fn write_to(
    terminal: Arc<TerminalInput>,
    write: impl FnOnce(&TerminalInput) -> io::Result<()> + Send + 'static,
) -> io::Result<()> {
    tokio::task::spawn_blocking(move || write(&terminal))
        .await
        .map_err(io::Error::other)?
}

pub(crate) async fn write_input(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
    sequence: u64,
    bytes: TerminalBytes,
) -> io::Result<()> {
    let terminal = input(core, id, shell_id).await?;
    write_to(terminal, move |terminal| {
        terminal.write_sequenced(sequence, bytes.as_bytes(), TERMINAL_INPUT_WRITE_TIMEOUT)
    })
    .await
}

/// Types `text` into a pane as a keyboard would, outside its input sequence: for agents driving
/// panes (RFD0015). Control characters act as keys.
pub(crate) async fn write_text(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
    text: TerminalText,
) -> io::Result<()> {
    let terminal = handle(core, id)?
        .with(move |session| session.input(shell_id))
        .await??;
    log::info!(
        "event=terminal.write session_id={id} shell_id={} bytes={}",
        shell_id.get(),
        text.as_bytes().len()
    );
    write_to(terminal, move |terminal| {
        terminal.write(text.as_bytes(), TERMINAL_INPUT_WRITE_TIMEOUT)
    })
    .await
}

/// The last `lines` lines of a pane's screen and scrollback as plain text, and whether earlier
/// lines were left out.
pub(crate) async fn screen(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
    lines: usize,
) -> io::Result<rpc::TerminalScreen> {
    let output = match core
        .peers
        .with_pane(Some(id), shell_id, |_, running| Arc::clone(&running.output))
    {
        Some(output) => output,
        None => {
            handle(core, id)?
                .with(move |session| session.output(shell_id))
                .await??
        }
    };
    let text = output.screen_text();
    let (text, truncated) = last_lines(&text, lines);
    Ok(rpc::TerminalScreen {
        text: text.to_owned(),
        truncated,
    })
}

pub(crate) async fn resize(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
    size: WindowSize,
) -> io::Result<()> {
    if let Some(resized) = core.peers.with_pane(Some(id), shell_id, |_, running| {
        axo_pty::process::resize(&running.master, &running.child, size)
    }) {
        return resized;
    }
    handle(core, id)?
        .with(move |session| session.resize(shell_id, size))
        .await?
}

pub(crate) async fn busy(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
) -> io::Result<rpc::ShellBusy> {
    if core
        .peers
        .with_pane(Some(id), shell_id, |_, _| ())
        .is_some()
    {
        // A remote pane runs nothing here: closing it stops nothing.
        return Ok(rpc::ShellBusy {
            busy: false,
            foreground_process: None,
        });
    }
    handle(core, id)?
        .with(move |session| session.busy(shell_id))
        .await?
}

/// Starts the Session's dormant Pi (`only`: if it is that pane); whether it was dormant.
pub(crate) async fn wake(core: &Core, id: SessionId, only: Option<ShellId>) -> io::Result<bool> {
    if only.is_some_and(|shell_id| {
        core.peers
            .with_pane(Some(id), shell_id, |_, _| ())
            .is_some()
    }) {
        return Ok(false);
    }
    handle(core, id)?
        .call(move |session| Box::pin(session.wake(only)))
        .await
}

/// Presses one key in the Session's Pi pane, as a person at the Mac would: Escape stops a reply
/// or declines a question, Enter accepts one. A Pi still starting has nothing to stop or answer,
/// so the key is not queued like a prompt.
pub(crate) async fn press_key(core: &Core, id: SessionId, key: PiKey) -> io::Result<()> {
    let terminal = handle(core, id)?
        .with(|session| session.pi_input())
        .await??;
    let bytes: &'static [u8] = match key {
        PiKey::Escape => b"\x1b",
        PiKey::Enter => b"\r",
    };
    log::info!("event=session.pi_key_pressed session_id={id} key={key:?}");
    write_to(terminal, move |terminal| {
        terminal.write(bytes, TERMINAL_INPUT_WRITE_TIMEOUT)
    })
    .await
}

/// Stops the Session's running run if anything in `stop` belongs to it; whether it did.
pub(crate) async fn stop_turn(core: &Core, id: SessionId, stop: StopTarget) -> io::Result<bool> {
    let link = handle(core, id)?
        .with(|session| session.pi_link())
        .await??;
    let stopped = prompts::stop(&link, &stop).await.map_err(io::Error::from)?;
    log::info!("event=session.pi_turn_stop session_id={id} stopped={stopped}");
    Ok(stopped)
}

pub(crate) async fn pi_commands(core: &Core, id: SessionId) -> io::Result<Vec<PiCommandInfo>> {
    handle(core, id)?
        .with(|session| session.pi_commands())
        .await
}

pub(crate) async fn pi_models(core: &Core, id: SessionId) -> io::Result<Vec<PiModelInfo>> {
    handle(core, id)?.with(|session| session.pi_models()).await
}

pub(crate) async fn set_model(
    core: &Core,
    id: SessionId,
    model: Option<(String, String)>,
    thinking_level: Option<ThinkingLevel>,
) -> io::Result<()> {
    let link = handle(core, id)?
        .with(|session| session.pi_link())
        .await??;
    let set = session_task::pi::set_model(
        &link,
        model
            .as_ref()
            .map(|(provider, model)| (provider.as_str(), model.as_str())),
        thinking_level,
    )
    .await;
    log::info!(
        "event=session.pi_model_set session_id={id} outcome={}",
        set.as_ref()
            .map_or_else(|error| error.to_string(), |()| "accepted".to_owned())
    );
    set
}

pub(crate) async fn restart_for_client(core: &Core, id: SessionId) -> io::Result<()> {
    handle(core, id)?
        .call(|session| Box::pin(session.restart_for_client()))
        .await?
}

/// Starts an unavailable Pi pane and returns the Session once it is up.
pub(crate) async fn restart_unavailable(
    core: &Core,
    id: SessionId,
    shell_id: ShellId,
) -> io::Result<SessionRecord> {
    let handle = handle(core, id)?;
    let (waiter, started) = oneshot::channel();
    handle
        .call(move |session| Box::pin(session.restart_unavailable(shell_id, waiter)))
        .await??;
    match tokio::time::timeout(RESTART_WAIT, started).await {
        Ok(Ok(Ok(()))) => handle.with(|session| session.record()).await,
        Ok(Ok(Err(message))) => Err(io::Error::other(message)),
        Ok(Err(_)) => Err(io::Error::new(
            io::ErrorKind::NotFound,
            "This Pi pane is no longer available to restart.",
        )),
        Err(_) => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Pi is still starting",
        )),
    }
}

/// The last `count` lines of `text`, and whether any came before them.
pub(crate) fn last_lines(text: &str, count: usize) -> (&str, bool) {
    if count == 0 {
        return ("", !text.is_empty());
    }
    match text.rmatch_indices('\n').nth(count - 1) {
        Some((index, _)) => (&text[index + 1..], true),
        None => (text, false),
    }
}

/// Closes a Session; nothing opens in its place (RFD0038).
pub(crate) async fn close_session(core: &Core, id: SessionId) -> io::Result<()> {
    sessions::close(core, id).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_lines_of_a_screen_say_whether_earlier_ones_were_left_out() {
        assert_eq!(last_lines("a\nb\nc", 2), ("b\nc", true));
        assert_eq!(last_lines("a\nb", 5), ("a\nb", false));
        assert_eq!(last_lines("", 0), ("", false));
        assert_eq!(last_lines("a", 0), ("", true));
    }
}
