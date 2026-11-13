# RFD0045 - Axo: idle Pis go to sleep

- Feature Name: `idle-pis-sleep`
- Status: Proposal
- Author: leostera
- Start Date: 2026-11-12
- Updated: 2026-11-12
- Document Type: Proposal
- Amends: [RFD0041](RFD0041-axod-session-tasks.md) (a Pi's states: a running Pi can become dormant)

## Summary

axod stops the Pi of a Session nobody is using, and the Session keeps its place: its Pi pane turns dormant, as it is after a restart, and starts again when the Session is shown, prompted or typed into. A Pi sleeps after 30 minutes without activity, and at most 20 idle Pis are kept awake: past that, the longest idle go first. Pis that are working, or asking the person something, are never stopped and not counted. Both limits are settings, under Settings → Sessions → Limits on the Mac.

## Motivation

A Pi starts for every Session that is shown, prompted or typed into, and nothing stops it until the Session closes. Sessions are cheap to open and stay open for days, so their Pis pile up. On the author's Mac on 2026-11-12, 174 open Sessions had 66 Pis running, using 3.9 GB of memory between them; almost none were doing anything. Nothing bounds it: an agent that opens Sessions in a loop starts a Pi for each, and 1000 of them would take the Mac down.

Working Sessions are left alone: they are what the person is waiting on, they come in bursts, and a cap on them would stop work that was asked for.

## Guide-level explanation

A Pi is **idle** when it is running, connected, not working, not asking the person anything, has no prompts waiting for it, and is not being restarted. Its **idle time** is how long it has been since anything happened in it: it started, it reported an event on its bridge (a turn, a message, a change of model), a prompt reached it, or its terminal showed anything (typing in the pane echoes, so typing counts).

Once a minute, axod looks at every idle Pi and:

1. puts to sleep each one idle for at least the **idle timeout** (30 minutes);
2. then, if more than the **idle limit** (20) are still awake, puts to sleep the longest idle of those idle for at least a minute, until the limit holds. The minute is so that a Pi between two prompts of a burst is not counted as idle.

Putting a Pi to sleep is a restart without the start: axod asks Pi to exit on its bridge, kills it if it has not after ten seconds, and the pane is dormant once it has gone. A prompt that arrives while it is exiting turns the sleep into a restart, and the prompt waits for the new Pi.

A dormant Pi starts again as it always has: when the Mac shows its Session to the person, when a client prompts it, or when someone types into it from the phone or the web. The Mac wakes the selected Session's Pi only while the person is looking at Axo, so a Session left selected while the person is in another app sleeps and stays asleep until they come back.

The settings are daemon settings, read and changed with `axo.config.get` and `axo.config.set`:

- `sessions.idleMinutes`: the idle timeout in minutes, `0` for never. 30 by default.
- `sessions.idleLimit`: how many idle Pis stay awake, `0` for none. 20 by default.

Changes apply at the next look.

## Reference-level explanation

- `axo_pty::TerminalOutput` records when it last recorded output, and the Session reads it from its Pi pane's output.
- `Session::pi_idle()` answers the Pi's idle time, or nothing when it is not idle by the rule above.
- `Session::sleep_pi()` asks a running, idle Pi to exit with the restart's grace and kill, marking it to become dormant (`PiState::Dormant`) rather than unavailable when it exits. If it is no longer idle by the time the Session handles it, nothing happens.
- The governor (`crates/axo-server/src/idle_pis.rs`) is a task axod starts once Sessions are restored. Each minute it asks every open Session for its Pi's idle time, chooses with `choose(idle, limits)`, a pure function, and asks the chosen Sessions to sleep. It ends when axod stops.
- Settings: `ConfigKey::IdleMinutes` (`sessions.idleMinutes`, stored as `sessions_idle_minutes`) and `ConfigKey::IdleLimit` (`sessions.idleLimit`, `sessions_idle_limit`), each a whole number from 0 to 10000.
- The Mac: `TerminalSessionsModel.wakeSelectedPi` runs only while `isLookingAtSelection()`, and again when Axo becomes active. Settings → Sessions gains a Limits section with both values.

## Drawbacks

- A Pi waking takes a second or two, so coming back to a Session after half an hour shows "Starting Pi…" briefly.
- A Pi's terminal output is how typing is seen, because the Mac writes to the pane's PTY directly. A Pi whose screen changes on its own while idle would never time out; the limit still bounds those.
- Something the person typed into Pi's editor and never sent is lost when it sleeps.

## Rationale and alternatives

- **A cap on all Pis.** Rejected: it would stop or refuse work the person asked for.
- **Tell axod what the Mac is showing, and never sleep that.** More protocol for one Session; waking on return does as well.
- **Stop terminals too.** Shells are cheap and hold state the person cares about (a running server, a history); not now.

## Unresolved questions

- Whether the defaults are right; they are settings so they can be tried.
