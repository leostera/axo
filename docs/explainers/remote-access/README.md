# Axo Remote Access Playground

An interactive visualization showing how Axo's remote access system works: how Macs get linked to accounts, how phones and browsers reach them, and what every part remembers.

## Features

### Interactive Canvas
- **Full-screen playground** - uses 100% of viewport
- **Drag and drop** - drag people onto devices to sign in
- **Click interactions** - click devices and Macs for context menus
- **Live simulation** - watch packets fly, connections animate, state changes
- **Time controls** - play/pause, speed up (¼×, 1×, 5×, 25×), step forward
- **Dark/light mode** - theme toggle in top-right corner

### Timeline & History
- **Event timeline** (right sidebar) - shows last 50 events
- **Click to preview** - click any event to see that moment in time
- **Rollback button** - confirm button appears to permanently roll back
- **Visual feedback** - selected events highlighted in blue
- **URL sharing** - the run (preset + your inputs) is in the URL; links replay, timeline included

### Presets
Three starting scenarios:
- **Fresh start** - empty system, ready to explore
- **Alice has a linked Mac** - one person, one device, already linked
- **Two people, three Macs** - family setup with multiple accounts

### Proposed Changes
Toggle experimental features:
- **Unlink button on Macs** - test unlinking flow
- **At most 3 waiting codes** - test code limits

## URL Sharing 🔗

The URL always describes the run you are looking at, so you can copy it at any point, share it, and
whoever opens it sees the same thing, **including the timeline**: they can preview and roll back.

```
#play/{preset}/r={lz-compressed JSON: {inputs: [{at, command}], now}}
```

The URL stores *what people did*, not the resulting state: the starting preset, every command
(`src/commands.ts`) with the simulated time it happened at, and the current time. Opening a link
replays the commands on the preset (`src/replay.ts`), which also rebuilds the time-travel history.
That keeps links short (a few hundred characters for a typical session) and works because the
simulator is deterministic: no randomness, no wall-clock reads. `src/replay.test.ts` checks that a
replay reproduces a live run exactly; keep it passing when you change `sim.ts`.

- Every UI action goes through `perform(sim, command)`, which runs it and records it in `sim.inputs`.
  A new kind of action means a new variant in `commands.ts` and a case in `replay.ts`.
- The URL is rewritten on every action or simulated event, and twice a second plus on page hide for
  the time position.
- A link that does not parse, names things that don't exist, or fails to replay falls back to the
  preset instead of loading something half-applied.
- A loaded link starts paused so you can look before pressing Play.

Because old links store a different shape, changing the rules in `sim.ts` can change what an old
link replays to. That is fine for an explainer; there is no compatibility promise.

Run the tests with `npx tsx --test src/replay.test.ts`.

## How to Use

1. **Choose a preset** (top-right tabs) or start fresh
2. **Drag people** from top-left onto devices to sign in through Access
3. **Click devices** to generate pairing codes or connect to Macs
4. **Click Macs** to simulate Wi-Fi drops, restarts, or terminals
5. **Watch the relay** show accounts, Macs, and connections in real-time
6. **Use the timeline** to jump back to any moment
7. **Share the URL** to show someone a specific state

## Technical Details

- **Size:** 1.04 MB (297 KB gzipped)
- **Framework:** React + Vite + Motion (animations)
- **Design:** Cloudflare Kumo design system
- **Simulator:** `src/sim.ts` - discrete-event simulation engine
- **Canvas:** SVG with 1200×720 user units

## Development

```bash
npm install
npm run dev     # Dev server
npm run build   # Production build
```

The simulator in `src/sim.ts` mirrors the real implementation in:
- `crates/axo-relay/src/link.rs` (Rust)
- `crates/axo-relay/src/relay.rs` (Rust)
- `packages/axo-api-worker/src/auth/*` (TypeScript)
- `packages/axo-api-worker/src/relay/peer.ts` (TypeScript)

When the real code changes, update `src/sim.ts` to match.
