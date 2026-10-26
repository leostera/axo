// The playground: the simulator drawn as a living diagram you play with directly. Drag people
// onto devices, drag pairing tickets onto Macs, click things to poke them, and watch packets fly.

import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { AnimatePresence, motion } from "motion/react";
import { Button } from "@cloudflare/kumo/components/button";
import { Switch } from "@cloudflare/kumo/components/switch";
import { Tabs } from "@cloudflare/kumo/components/tabs";
import { Text } from "@cloudflare/kumo/components/text";
import {
  ArrowCounterClockwiseIcon,
  ArrowLeftIcon,
  CloudIcon,
  DesktopIcon,
  DeviceMobileIcon,
  FastForwardIcon,
  LaptopIcon,
  LinkIcon,
  MoonIcon,
  PauseIcon,
  PlayIcon,
  PlusIcon,
  ShieldCheckIcon,
  SignOutIcon,
  SkipForwardIcon,
  SunIcon,
  TerminalWindowIcon,
  TicketIcon,
  TrashIcon,
  WifiHighIcon,
  WifiSlashIcon,
  XIcon,
} from "@phosphor-icons/react";
import {
  addClient,
  addMac,
  addPerson,
  clientActions,
  hostStatus,
  macActions,
  nextEventAt,
  personName,
  presets,
  setFlag,
  skip,
  type Account,
  type Client,
  type HostRecord,
  type LogEntry,
  type Mac,
  type NodeId,
  type Packet,
  type Sim,
  type Tone,
} from "./sim";
import { EventLog, HISTORY, formatDuration, formatTime, useAnimation, type Model } from "./simulator";
import { encodeRun, loadHash } from "./share";
import { perform } from "./replay";
import type { Command } from "./commands";

function writeUrl(sim: Sim) {
  const presetId = location.hash.split("/")[1] || "fresh";
  history.replaceState(null, "", `#play/${presetId}/r=${encodeRun(sim)}`);
}

// ---------- Geometry (SVG user units; the overlay uses the same box via percentages) ----------

const W = 1200;
const H = 720;
const CLOUD = { x: 390, y: 60, w: 420, h: 610 };
const ACCESS = { x: CLOUD.x, y: 380 };
const RELAY = { x: CLOUD.x + CLOUD.w / 2, y: 140 };
const BUBBLE = { x: CLOUD.x + 40, w: CLOUD.w - 80, top: 220, header: 30, row: 30, codes: 26, gap: 12 };
const CLIENT_X = 150;
const MAC_X = 1050;
const NODE_R = 34;

type Point = { x: number; y: number };

// Use CSS custom properties so they respect light/dark mode
const PERSON_COLORS = [
  "var(--color-blue-500)",
  "var(--color-pink-500)",
  "var(--color-amber-500)",
  "var(--color-green-500)",
  "var(--color-purple-500)",
  "var(--color-red-500)",
];
const TONE_COLOR: Record<Tone, string> = {
  request: "var(--color-blue-500)",
  reply: "var(--color-green-500)",
  refused: "var(--color-orange-500)",
  stream: "var(--color-purple-500)",
  lost: "var(--color-red-500)",
};
const STATE_COLOR = {
  "not linked": "var(--color-kumo-line)",
  connecting: "var(--color-amber-500)",
  connected: "var(--color-green-500)",
  disconnected: "var(--color-red-500)",
} as const;

const MAC_NAMES = ["Studio", "MacBook", "Mac mini", "iMac", "Mac Pro", "Work MacBook"];
const PEOPLE = ["Alice", "Bob", "Carol", "Dan", "Erin"];
const COMMANDS = ["ls", "whoami", "date"];

function spread(count: number, index: number, top = 130, bottom = 610): number {
  if (count <= 1) return (top + bottom) / 2;
  const step = Math.min((bottom - top) / (count - 1), 150);
  const start = (top + bottom) / 2 - (step * (count - 1)) / 2;
  return start + step * index;
}

type Layout = {
  clients: Map<string, Point>;
  macs: Map<string, Point>;
  accounts: { account: Account; y: number; height: number; hosts: Map<string, Point> }[];
};

function layout(sim: Sim): Layout {
  const clients = new Map(sim.clients.map((c, i) => [c.id, { x: CLIENT_X, y: spread(sim.clients.length, i) }]));
  const macs = new Map(sim.macs.map((m, i) => [m.id, { x: MAC_X, y: spread(sim.macs.length, i) }]));
  let y = BUBBLE.top;
  const accounts = Object.values(sim.relay.accounts).map((account) => {
    const hosts = Object.values(account.hosts);
    const codes = liveCodes(sim, account.id).length > 0;
    const height = BUBBLE.header + Math.max(hosts.length, 1) * BUBBLE.row + (codes ? BUBBLE.codes : 0) + 8;
    const entry = {
      account,
      y,
      height,
      hosts: new Map(hosts.map((h, i) => [h.hostId, { x: BUBBLE.x + BUBBLE.w / 2, y: y + BUBBLE.header + i * BUBBLE.row + BUBBLE.row / 2 }])),
    };
    y += height + BUBBLE.gap;
    return entry;
  });
  return { clients, macs, accounts };
}

function liveCodes(sim: Sim, accountId: string) {
  return sim.relay.codes.filter((c) => c.account === accountId && !c.usedBy && c.expiresAt > sim.now);
}

function personColor(sim: Sim, personId: string | null | undefined): string {
  const index = sim.people.findIndex((p) => p.id === personId);
  return index < 0 ? "var(--color-kumo-line)" : PERSON_COLORS[index % PERSON_COLORS.length]!;
}

function accountColor(sim: Sim, accountId: string | null): string {
  return accountId ? personColor(sim, sim.relay.accounts[accountId]?.person) : "var(--color-kumo-line)";
}

/** Where a host's relay object sits, if the relay knows the host. */
function hostChip(geo: Layout, accountId: string | null | undefined, hostId: string): Point | null {
  return geo.accounts.find((a) => a.account.id === accountId)?.hosts.get(hostId) ?? null;
}

function hostChipFor(sim: Sim, geo: Layout, hostId: string): Point | null {
  for (const entry of geo.accounts) {
    const chip = entry.hosts.get(hostId);
    if (chip) return chip;
  }
  return null;
}

function nodePoint(sim: Sim, geo: Layout, node: NodeId): Point {
  if (node === "access") return ACCESS;
  if (node === "relay") return RELAY;
  if (node.startsWith("client:")) return geo.clients.get(node.slice(7)) ?? { x: CLIENT_X, y: H / 2 };
  return geo.macs.get(node.slice(4)) ?? { x: MAC_X, y: H / 2 };
}

/** Host traffic goes to the host's spot in its account; everything else to the relay itself. */
function relayEnd(sim: Sim, geo: Layout, packet: Packet, peer: NodeId): Point {
  const b = packet.body;
  const side = (chip: Point | null) =>
    chip ? { x: peer.startsWith("mac:") ? BUBBLE.x + BUBBLE.w - 16 : BUBBLE.x + 16, y: chip.y } : RELAY;
  switch (b.t) {
    case "connect":
    case "register":
    case "host.output":
    case "bye":
      return side(hostChip(geo, b.account, b.hostId));
    case "accepted":
    case "refused":
    case "close":
    case "relay.input": {
      const mac = peer.startsWith("mac:") ? sim.macs.find((m) => m.id === peer.slice(4)) : null;
      return side(mac ? hostChipFor(sim, geo, mac.hostId) : null);
    }
    case "output":
    case "host.status":
    case "opened": {
      const client = sim.clients.find((c) => `client:${c.id}` === peer);
      const hostId = b.t === "output" ? client?.attached : b.hostId;
      return side(hostId ? hostChipFor(sim, geo, hostId) : null);
    }
    default:
      return RELAY;
  }
}

function packetEnds(sim: Sim, geo: Layout, packet: Packet): [Point, Point] {
  const from = packet.from === "relay" ? relayEnd(sim, geo, packet, packet.to) : nodePoint(sim, geo, packet.from);
  const to = packet.to === "relay" ? relayEnd(sim, geo, packet, packet.from) : nodePoint(sim, geo, packet.to);
  return [from, to];
}

function curve(a: Point, b: Point, bend: number) {
  const mx = (a.x + b.x) / 2;
  const my = (a.y + b.y) / 2;
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  const length = Math.hypot(dx, dy) || 1;
  const c = { x: mx - (dy / length) * bend, y: my + (dx / length) * bend };
  return {
    d: `M ${a.x} ${a.y} Q ${c.x} ${c.y} ${b.x} ${b.y}`,
    at: (t: number) => ({
      x: (1 - t) ** 2 * a.x + 2 * (1 - t) * t * c.x + t ** 2 * b.x,
      y: (1 - t) ** 2 * a.y + 2 * (1 - t) * t * c.y + t ** 2 * b.y,
    }),
  };
}

function isLost(sim: Sim, packet: Packet): boolean {
  if (packet.lost) return true;
  if (!packet.to.startsWith("mac:")) return false;
  const mac = sim.macs.find((m) => `mac:${m.id}` === packet.to);
  return !mac || !mac.online;
}

// ---------- Interaction state ----------

type Selection = { kind: "client"; id: string } | { kind: "mac"; id: string } | { kind: "host"; account: string; hostId: string } | null;
type Drag = { kind: "person"; personId: string; at: Point } | { kind: "ticket"; code: string; at: Point } | null;
type Picking = { clientId: string } | null;
type Bubble = { key: number; node: LogEntry["node"]; text: string; tone: LogEntry["tone"]; born: number };


function Timeline({ 
  sim, 
  currentSim,
  history, 
  previewIndex,
  onSelect,
  onCancel,
  onRollback
}: { 
  sim: Sim; 
  currentSim: Sim;
  history: Sim[]; 
  previewIndex: number | null;
  onSelect: (index: number) => void;
  onCancel: () => void;
  onRollback: (index: number) => void;
}) {
  const events = [...currentSim.log].reverse().slice(0, 50);
  const currentTime = currentSim.now;
  const isPreviewing = previewIndex !== null;
  
  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex items-center justify-between">
        <Text size="sm" bold>Timeline</Text>
        <Text size="xs" variant="secondary">{events.length} events</Text>
      </div>
      
      {isPreviewing && (
        <motion.div
          initial={{ opacity: 0, y: -10 }}
          animate={{ opacity: 1, y: 0 }}
          className="flex items-center justify-between gap-2 rounded-lg bg-kumo-brand p-3"
        >
          <Text size="xs" bold>
            Preview: {formatTime(sim.now)}
          </Text>
          <div className="flex gap-2">
            <Button
              size="xs"
              variant="primary"
              onClick={() => onRollback(previewIndex)}
            >
              <ArrowCounterClockwiseIcon size={12} /> Rollback
            </Button>
            <Button
              size="xs"
              variant="ghost"
              onClick={onCancel}
            >
              <XIcon size={12} />
            </Button>
          </div>
        </motion.div>
      )}
      
      <div className="flex-1 space-y-1 overflow-y-auto">
        {events.map((event) => {
          const isPast = event.at <= currentTime;
          const canInteract = isPast && history.length > 0;
          const targetIndex = history.findIndex((h) => h.now >= event.at);
          const isSelected = previewIndex === targetIndex;
          
          return (
            <motion.button
              key={event.id}
              initial={{ opacity: 0, x: 10 }}
              animate={{ opacity: 1, x: 0 }}
              onClick={() => {
                if (canInteract && targetIndex >= 0) {
                  if (isSelected) {
                    onCancel();
                  } else {
                    onSelect(targetIndex);
                  }
                }
              }}
              disabled={!canInteract}
              className={`w-full rounded-lg px-3 py-2 text-left transition-colors ${
                isSelected
                  ? "bg-kumo-brand text-white ring-2 ring-kumo-brand ring-offset-2 ring-offset-kumo-elevated"
                  : isPast && canInteract
                  ? "bg-kumo-base hover:bg-kumo-tint cursor-pointer"
                  : "bg-kumo-recessed opacity-50 cursor-not-allowed"
              }`}
            >
              <div className="flex items-start gap-2">
                <span className={`font-mono text-[10px] font-semibold ${isSelected ? "text-white/70" : "text-kumo-subtle"}`}>
                  {formatTime(event.at)}
                </span>
                <div className="flex-1 space-y-0.5">
                  <div className="text-xs font-medium">{event.title}</div>
                </div>
              </div>
            </motion.button>
          );
        })}
      </div>
    </div>
  );
}

export function Playground({ dark, onToggleDark }: { dark: boolean; onToggleDark: () => void }) {
  const [model, setModel] = useState<Model>(() => {
    const { presetId, shared } = loadHash(location.hash);
    if (shared) return { ...shared, mode: "paused", stepFrom: 0, stepTo: 0 };
    const sim = (presets.find((p) => p.id === presetId) ?? presets[0]!).build();
    return { sim, history: [], mode: "playing", stepFrom: 0, stepTo: 0 };
  });
  const [speed, setSpeed] = useState("1");
  const [selection, setSelection] = useState<Selection>(null);
  const [picking, setPicking] = useState<Picking>(null);
  const [drag, setDrag] = useState<Drag>(null);
  const [terminals, setTerminals] = useState<Set<string>>(new Set());
  const [bubbles, setBubbles] = useState<Bubble[]>([]);
  const [previewIndex, setPreviewIndex] = useState<number | null>(null);
  const canvas = useRef<HTMLDivElement>(null);
  const seen = useRef(0);
  const sim = previewIndex !== null && model.history[previewIndex] ? model.history[previewIndex]! : model.sim;
  const geo = layout(sim);

  useAnimation(model, setModel, Number(speed), true);

  const apply = (command: Command) =>
    setModel((m) => ({ ...m, sim: perform(m.sim, command), history: [...m.history, m.sim].slice(-HISTORY) }));

  // Keep the URL equal to the current simulation. `history` gets a new identity on every action,
  // simulated event, rollback and reset (and not on frames that only advance time), so that is
  // the immediate write. The timer and `pagehide` cover the time position.
  const latest = useRef(model.sim);
  latest.current = model.sim;
  useEffect(() => writeUrl(model.sim), [model.history]);
  useEffect(() => {
    const save = () => writeUrl(latest.current);
    const timer = setInterval(save, 500);
    addEventListener("pagehide", save);
    return () => {
      clearInterval(timer);
      removeEventListener("pagehide", save);
    };
  }, []);

  // Speech bubbles for new events, at the node where they happened.
  useEffect(() => {
    const fresh = sim.log.filter((e) => e.id > seen.current && e.tone !== "action");
    if (sim.log[0]) seen.current = Math.max(seen.current, sim.log[0].id);
    if (fresh.length === 0) return;
    const now = performance.now();
    setBubbles((old) => {
      const latest = new Map<string, Bubble>();
      for (const bubble of old) if (now - bubble.born < 3200) latest.set(bubble.node, bubble);
      for (const entry of [...fresh].reverse()) {
        latest.set(entry.node, { key: entry.id, node: entry.node, text: entry.title, tone: entry.tone, born: now });
      }
      return [...latest.values()];
    });
  }, [sim.log]);
  useEffect(() => {
    const timer = setInterval(() => {
      const now = performance.now();
      setBubbles((old) => (old.some((b) => now - b.born >= 3200) ? old.filter((b) => now - b.born < 3200) : old));
    }, 400);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setPicking(null);
        setSelection(null);
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  const toUnits = (event: { clientX: number; clientY: number }): Point => {
    const box = canvas.current!.getBoundingClientRect();
    return { x: ((event.clientX - box.left) / box.width) * W, y: ((event.clientY - box.top) / box.height) * H };
  };

  const nearest = <T,>(points: Map<string, Point>, at: Point, within = 70): string | null => {
    let best: string | null = null;
    let distance = within;
    for (const [id, point] of points) {
      const d = Math.hypot(point.x - at.x, point.y - at.y);
      if (d < distance) {
        best = id;
        distance = d;
      }
    }
    return best;
  };

  const dropTarget = drag ? nearest(drag.kind === "person" ? geo.clients : geo.macs, drag.at) : null;

  const startDrag = (event: ReactPointerEvent, next: NonNullable<Drag>) => {
    event.preventDefault();
    (event.target as Element).setPointerCapture?.(event.pointerId);
    setDrag(next);
  };

  const onPointerMove = (event: ReactPointerEvent) => {
    if (drag) setDrag({ ...drag, at: toUnits(event) });
  };

  const onPointerUp = (event: ReactPointerEvent) => {
    if (!drag) return;
    const at = toUnits(event);
    if (drag.kind === "person") {
      const clientId = nearest(geo.clients, at);
      if (clientId) apply({ t: "signIn", client: clientId, person: drag.personId });
    } else {
      const macId = nearest(geo.macs, at);
      if (macId) apply({ t: "link", mac: macId, code: drag.code });
    }
    setDrag(null);
  };

  const clickMac = (mac: Mac) => {
    if (picking) {
      apply({ t: "open", client: picking.clientId, hostId: mac.hostId });
      setTerminals((t) => new Set(t).add(`client:${picking.clientId}`));
      setPicking(null);
      return;
    }
    setSelection({ kind: "mac", id: mac.id });
  };

  const reset = (presetId: string) => {
    const preset = presets.find((p) => p.id === presetId) ?? presets[0]!;
    history.replaceState(null, "", `#play/${preset.id}`);
    setModel({ sim: preset.build(), history: [], mode: "playing", stepFrom: 0, stepTo: 0 });
    setSelection(null);
    setPicking(null);
    setTerminals(new Set());
  };

  const nextMac = MAC_NAMES.find((n) => !sim.macs.some((m) => m.name === n)) ?? `Mac ${sim.macs.length + 1}`;
  const nextPerson = PEOPLE.find((n) => !sim.people.some((p) => p.name === n)) ?? `Person ${sim.people.length + 1}`;
  const countKind = (kind: Client["kind"]) => sim.clients.filter((c) => c.kind === kind).length + 1;

  return (
    <div className="flex h-full flex-col gap-3">
      <div className="flex flex-shrink-0 flex-wrap items-center justify-between gap-3">
        <Hint sim={sim} picking={picking} />
        <div className="flex items-center gap-2">
          <Tabs
            size="sm"
            value=""
            onValueChange={reset}
            tabs={presets.map((p) => ({ value: p.id, label: p.name }))}
          />
          <Button
            shape="square"
            variant="ghost"
            size="sm"
            aria-label="Toggle dark mode"
            icon={dark ? <SunIcon size={16} /> : <MoonIcon size={16} />}
            onClick={onToggleDark}
          />
        </div>
      </div>

      <div className="flex flex-1 gap-3 overflow-hidden">
        <div
          ref={canvas}
          className="relative flex-1 select-none overflow-hidden rounded-2xl bg-kumo-recessed shadow-lg ring-1 ring-kumo-line"
        style={{ aspectRatio: `${W} / ${H}`, width: `min(100%, calc((100vh - 210px) * ${W / H}))`, touchAction: "none" }}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        onPointerDown={(event) => {
          if (event.target === event.currentTarget || (event.target as Element).tagName === "svg") {
            setSelection(null);
          }
        }}
      >
        <svg viewBox={`0 0 ${W} ${H}`} className="absolute inset-0 h-full w-full">
          <defs>
            <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="4" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
            <linearGradient id="cloud" x1="0" x2="0" y1="0" y2="1">
              <stop offset="0" stopColor="#f6821f" stopOpacity="0.14" />
              <stop offset="1" stopColor="#f6821f" stopOpacity="0.04" />
            </linearGradient>
          </defs>

          <Cloud />
          <Sockets sim={sim} geo={geo} />
          <AccountBubbles sim={sim} geo={geo} selection={selection} onSelect={setSelection} />

          <AccessGate sim={sim} />
          <RelayCore />

          {sim.clients.map((client) => (
            <ClientNode
              key={client.id}
              sim={sim}
              client={client}
              at={geo.clients.get(client.id)!}
              selected={selection?.kind === "client" && selection.id === client.id}
              target={drag?.kind === "person" && dropTarget === client.id}
              onClick={() => setSelection({ kind: "client", id: client.id })}
            />
          ))}
          {sim.macs.map((mac) => (
            <MacNode
              key={mac.id}
              sim={sim}
              mac={mac}
              at={geo.macs.get(mac.id)!}
              selected={selection?.kind === "mac" && selection.id === mac.id}
              target={(drag?.kind === "ticket" && dropTarget === mac.id) || picking !== null}
              onClick={() => clickMac(mac)}
            />
          ))}

          <Packets sim={sim} geo={geo} />
        </svg>

        {/* Overlay: things you hold, click and read. Positioned in the same units as the SVG. */}
        <PeopleDock sim={sim} onDrag={startDrag} onAdd={() => apply({ t: "addPerson", name: nextPerson })} />
        <AddDock
          onPhone={() => apply({ t: "addClient", kind: "phone", owner: "", label: `Phone ${countKind("phone")}` })}
          onBrowser={() => apply({ t: "addClient", kind: "browser", owner: "", label: `Browser ${countKind("browser")}` })}
          onMac={() => apply({ t: "addMac", name: nextMac })}
        />
        <Proposals sim={sim} apply={apply} />

        {sim.clients.map((client) => (
          <Tickets key={client.id} sim={sim} client={client} at={geo.clients.get(client.id)!} onDrag={startDrag} />
        ))}

        {sim.clients.map((client) =>
          client.attached && terminals.has(`client:${client.id}`) ? (
            <TerminalBubble
              key={client.id}
              at={geo.clients.get(client.id)!}
              side="right"
              title={`on ${sim.macs.find((m) => m.hostId === client.attached)?.name ?? "?"}`}
              lines={client.terminal}
              onRun={(command) => apply({ t: "clientType", client: client.id, text: command })}
              onClose={() => setTerminals((t) => without(t, `client:${client.id}`))}
            />
          ) : null,
        )}
        {sim.macs.map((mac) =>
          terminals.has(`mac:${mac.id}`) ? (
            <TerminalBubble
              key={mac.id}
              at={geo.macs.get(mac.id)!}
              side="left"
              title={`${mac.name}, locally`}
              lines={mac.terminal}
              onRun={(command) => apply({ t: "macType", mac: mac.id, text: command })}
              onClose={() => setTerminals((t) => without(t, `mac:${mac.id}`))}
            />
          ) : null,
        )}

        <AnimatePresence>
          {bubbles.map((bubble) => (
            <SpeechBubble key={bubble.key} sim={sim} geo={geo} bubble={bubble} />
          ))}
        </AnimatePresence>

        {selection && (
          <ActionBar
            sim={sim}
            geo={geo}
            selection={selection}
            apply={apply}
            terminals={terminals}
            toggleTerminal={(key) => setTerminals((t) => (t.has(key) ? without(t, key) : new Set(t).add(key)))}
            startPicking={(clientId) => {
              setPicking({ clientId });
              setSelection(null);
            }}
            close={() => setSelection(null)}
          />
        )}

        {drag && <DragGhost sim={sim} drag={drag} />}

        <Transport model={model} setModel={setModel} speed={speed} setSpeed={setSpeed} apply={apply} onReset={() => reset("fresh")} />


        </div>

        <div className="w-80 flex-shrink-0 overflow-hidden rounded-xl bg-kumo-elevated p-4 shadow-lg ring-1 ring-kumo-line">
          <Timeline 
            sim={sim}
            currentSim={model.sim}
            history={model.history}
            previewIndex={previewIndex}
            onSelect={(index) => {
              setPreviewIndex(index);
              setModel((m) => ({ ...m, mode: "paused" }));
            }}
            onCancel={() => {
              setPreviewIndex(null);
            }}
            onRollback={(index) => {
              setModel((m) => ({
                ...m,
                sim: m.history[index] || m.sim,
                history: m.history.slice(0, index),
                mode: "paused",
              }));
              setPreviewIndex(null);
            }}
          />
        </div>
      </div>
    </div>
  );
}

function without(set: Set<string>, key: string): Set<string> {
  const next = new Set(set);
  next.delete(key);
  return next;
}

const pct = (p: Point) => ({ left: `${(p.x / W) * 100}%`, top: `${(p.y / H) * 100}%` });

// ---------- SVG pieces ----------

function Cloud() {
  const { x, y, w, h } = CLOUD;
  return (
    <g>
      <rect x={x} y={y} width={w} height={h} rx={48} fill="url(#cloud)" stroke="#f6821f" strokeOpacity={0.35} strokeDasharray="6 6" />
      <text x={x + w / 2} y={y + h - 14} textAnchor="middle" fontSize={13} fill="#f6821f" opacity={0.8}>
        Cloudflare
      </text>
      <text x={CLIENT_X} y={100} textAnchor="middle" fontSize={12} fill="var(--color-kumo-line)">
        DEVICES · sign in with Access
      </text>
      <text x={MAC_X} y={100} textAnchor="middle" fontSize={12} fill="var(--color-kumo-line)">
        MACS · paired once with a code
      </text>
    </g>
  );
}

function AccessGate({ sim }: { sim: Sim }) {
  const sessions = Object.keys(sim.access.sessions).length;
  return (
    <g transform={`translate(${ACCESS.x} ${ACCESS.y})`}>
      <rect x={-30} y={-46} width={60} height={92} rx={14} fill="var(--color-kumo-elevated)" stroke="#f6821f" strokeWidth={2} />
      <ShieldCheckIcon x={-16} y={-34} size={32} color="#f6821f" />
      <text y={14} textAnchor="middle" fontSize={11} fontWeight={600} fill="var(--color-kumo-default, currentColor)" className="fill-current">
        Access
      </text>
      <text y={30} textAnchor="middle" fontSize={10} className="fill-current" opacity={0.6}>
        {sessions} signed in
      </text>
    </g>
  );
}

function RelayCore() {
  return (
    <g transform={`translate(${RELAY.x} ${RELAY.y})`}>
      <circle r={40} fill="var(--color-kumo-elevated)" stroke="#f6821f" strokeWidth={2} />
      <CloudIcon x={-18} y={-26} size={36} color="#f6821f" />
      <text y={22} textAnchor="middle" fontSize={11} fontWeight={600} className="fill-current">
        Axo relay
      </text>
      <text y={58} textAnchor="middle" fontSize={10} className="fill-current" opacity={0.55}>
        one room per account, one spot per Mac
      </text>
    </g>
  );
}

function AccountBubbles({ sim, geo, selection, onSelect }: { sim: Sim; geo: Layout; selection: Selection; onSelect: (s: Selection) => void }) {
  return (
    <g>
      {geo.accounts.length === 0 && (
        <text x={RELAY.x} y={BUBBLE.top + 20} textAnchor="middle" fontSize={12} className="fill-current" opacity={0.5}>
          No accounts yet: one appears the first time someone signs in and asks for something.
        </text>
      )}
      {geo.accounts.map(({ account, y, height, hosts }) => {
        const color = personColor(sim, account.person);
        const codes = liveCodes(sim, account.id);
        return (
          <motion.g key={account.id} initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
            <rect x={BUBBLE.x} y={y} width={BUBBLE.w} height={height} rx={14} fill="var(--color-kumo-base)" stroke={color} strokeWidth={1.5} />
            <circle cx={BUBBLE.x + 16} cy={y + 15} r={6} fill={color} />
            <text x={BUBBLE.x + 28} y={y + 19} fontSize={12} fontWeight={600} className="fill-current">
              {personName(sim, account.person)}'s account
            </text>
            <text x={BUBBLE.x + BUBBLE.w - 12} y={y + 19} fontSize={10} textAnchor="end" className="fill-current" opacity={0.5}>
              {account.id}
            </text>
            {hosts.size === 0 && (
              <text x={BUBBLE.x + 16} y={y + BUBBLE.header + 18} fontSize={11} className="fill-current" opacity={0.5}>
                no Macs yet
              </text>
            )}
            {Object.values(account.hosts).map((host) => (
              <HostRow
                key={host.hostId}
                host={host}
                at={hosts.get(host.hostId)!}
                selected={selection?.kind === "host" && selection.hostId === host.hostId && selection.account === account.id}
                onClick={() => onSelect({ kind: "host", account: account.id, hostId: host.hostId })}
              />
            ))}
            {codes.length > 0 && (
              <g transform={`translate(${BUBBLE.x + 16} ${y + height - BUBBLE.codes + 2})`}>
                <TicketIcon size={14} y={-2} color="#f59e0b" />
                <text x={20} y={10} fontSize={10} className="fill-current" opacity={0.7}>
                  {codes.length} code{codes.length > 1 ? "s" : ""} waiting (only a hash is kept) · {formatDuration(Math.min(...codes.map((c) => c.expiresAt)) - sim.now)}
                </text>
              </g>
            )}
          </motion.g>
        );
      })}
    </g>
  );
}

function HostRow({ host, at, selected, onClick }: { host: HostRecord; at: Point; selected: boolean; onClick: () => void }) {
  const status = hostStatus(host);
  const color = status === "online" ? "#22c55e" : status === "revoked" ? "#ef4444" : "var(--color-kumo-line)";
  return (
    <g className="cursor-pointer" onClick={onClick}>
      <rect
        x={BUBBLE.x + 8}
        y={at.y - 12}
        width={BUBBLE.w - 16}
        height={24}
        rx={8}
        fill={selected ? "var(--color-kumo-tint)" : "var(--color-kumo-recessed)"}
        stroke={selected ? "var(--color-kumo-brand)" : "none"}
      />
      <circle cx={BUBBLE.x + 22} cy={at.y} r={5} fill={color} className={status === "online" ? "pulse" : undefined} />
      <text x={BUBBLE.x + 34} y={at.y + 4} fontSize={12} className="fill-current" textDecoration={status === "revoked" ? "line-through" : undefined}>
        {host.label}
      </text>
      <text x={BUBBLE.x + BUBBLE.w - 16} y={at.y + 4} fontSize={10} textAnchor="end" className="fill-current" opacity={0.55}>
        {host.clients.length > 0 ? `👁 ${host.clients.length} · ` : ""}🔑 checks {host.credential}
      </text>
    </g>
  );
}

function Sockets({ sim, geo }: { sim: Sim; geo: Layout }) {
  const lines: ReactNode[] = [];
  for (const mac of sim.macs) {
    if (!mac.socketOpen) continue;
    const chip = hostChip(geo, mac.db.account, mac.hostId);
    const from = geo.macs.get(mac.id)!;
    if (!chip) continue;
    const c = curve({ x: from.x - NODE_R, y: from.y }, { x: BUBBLE.x + BUBBLE.w - 8, y: chip.y }, 0);
    // Offline but not noticed yet: both ends still believe in a connection that carries nothing.
    const dead = !mac.online;
    lines.push(
      <path key={`m${mac.id}`} d={c.d} fill="none" stroke={dead ? "var(--color-red-500)" : accountColor(sim, mac.db.account)} strokeWidth={2.5} className={dead ? undefined : "flow"} strokeDasharray={dead ? "2 8" : undefined} opacity={dead ? 0.5 : 0.8} />,
    );
  }
  for (const { account, hosts } of geo.accounts) {
    for (const host of Object.values(account.hosts)) {
      for (const viewer of host.clients) {
        const from = geo.clients.get(viewer);
        const chip = hosts.get(host.hostId);
        if (!from || !chip) continue;
        const c = curve({ x: from.x + NODE_R, y: from.y }, { x: BUBBLE.x + 8, y: chip.y }, 0);
        lines.push(<path key={`c${viewer}${host.hostId}`} d={c.d} fill="none" stroke="var(--color-purple-500)" strokeWidth={2} className="flow-slow" opacity={0.8} />);
      }
    }
  }
  return <g>{lines}</g>;
}

function ClientNode({ sim, client, at, selected, target, onClick }: { sim: Sim; client: Client; at: Point; selected: boolean; target: boolean; onClick: () => void }) {
  const Icon = client.kind === "phone" ? DeviceMobileIcon : DesktopIcon;
  const watching = client.attached ? sim.macs.find((m) => m.hostId === client.attached)?.name : null;
  const caption = client.lastError ?? (watching ? `watching ${watching}` : client.signedInAs ? "signed in" : "signed out");
  return (
    <g transform={`translate(${at.x} ${at.y})`} className="cursor-pointer" onClick={onClick}>
      {target && <circle r={NODE_R + 12} fill="none" stroke="var(--color-kumo-brand)" strokeWidth={2} strokeDasharray="4 4" className="pulse" />}
      <circle r={NODE_R} fill="var(--color-kumo-elevated)" stroke={selected ? "var(--color-kumo-brand)" : client.signedInAs ? personColor(sim, client.signedInAs) : "var(--color-kumo-line)"} strokeWidth={selected ? 3 : 2.5} />
      <Icon x={-16} y={-16} size={32} className="fill-current" />
      {client.signedInAs && (
        <g transform={`translate(${NODE_R - 6} ${-NODE_R + 6})`}>
          <circle r={11} fill={personColor(sim, client.signedInAs)} />
          <text y={4} textAnchor="middle" fontSize={11} fontWeight={700} fill="white">
            {personName(sim, client.signedInAs)[0]}
          </text>
        </g>
      )}
      <text y={NODE_R + 16} textAnchor="middle" fontSize={12} fontWeight={600} className="fill-current">
        {client.name}
      </text>
      <text y={NODE_R + 30} textAnchor="middle" fontSize={10} fill={client.lastError ? "var(--color-red-500)" : undefined} className={client.lastError ? undefined : "fill-current"} opacity={client.lastError ? 1 : 0.6}>
        {truncate(caption, 34)}
      </text>
    </g>
  );
}

function MacNode({ sim, mac, at, selected, target, onClick }: { sim: Sim; mac: Mac; at: Point; selected: boolean; target: boolean; onClick: () => void }) {
  const retry = sim.timers.find((t) => t.node === `mac:${mac.id}` && t.body.t === "retry");
  const caption = mac.state === "disconnected" && retry ? `retry in ${formatDuration(retry.at - sim.now)}` : mac.state;
  return (
    <g transform={`translate(${at.x} ${at.y})`} className="cursor-pointer" onClick={onClick}>
      {target && <circle r={NODE_R + 12} fill="none" stroke="var(--color-kumo-brand)" strokeWidth={2} strokeDasharray="4 4" className="pulse" />}
      <circle r={NODE_R} fill="var(--color-kumo-elevated)" stroke={selected ? "var(--color-kumo-brand)" : STATE_COLOR[mac.state]} strokeWidth={selected ? 3 : 3} className={mac.state === "connecting" ? "pulse" : undefined} />
      <LaptopIcon x={-17} y={-17} size={34} className="fill-current" />
      {mac.db.account && (
        <circle cx={-NODE_R + 6} cy={-NODE_R + 6} r={8} fill={accountColor(sim, mac.db.account)} stroke="var(--color-kumo-elevated)" strokeWidth={2}>
          <title>linked to {mac.db.account}</title>
        </circle>
      )}
      {!mac.online && (
        <g transform={`translate(${NODE_R - 8} ${-NODE_R + 6})`}>
          <circle r={11} fill="var(--color-red-500)" />
          <WifiSlashIcon x={-7} y={-7} size={14} color="white" />
        </g>
      )}
      {mac.db.pending && (
        <g transform={`translate(${NODE_R - 6} ${NODE_R - 8})`}>
          <circle r={9} fill="var(--color-amber-500)" />
          <text y={4} textAnchor="middle" fontSize={10} fontWeight={700} fill="white">
            …
          </text>
          <title>linking in progress: {mac.db.pending}</title>
        </g>
      )}
      <text y={NODE_R + 16} textAnchor="middle" fontSize={12} fontWeight={600} className="fill-current">
        {mac.name}
      </text>
      <text y={NODE_R + 30} textAnchor="middle" fontSize={10} className="fill-current" opacity={0.6}>
        {caption}
      </text>
      <g transform={`translate(${NODE_R + 8} ${-18})`} opacity={0.85}>
        <rect width={96} height={36} rx={6} fill="var(--color-kumo-base)" stroke="var(--color-kumo-line)" />
        <text x={6} y={14} fontSize={9} className="fill-current" opacity={0.6}>
          host_link
        </text>
        <text x={6} y={28} fontSize={10} className="fill-current">
          {mac.db.account ? `${mac.db.account.replace("acct-", "")} · ${mac.db.credential}` : "empty"}
        </text>
      </g>
    </g>
  );
}

function Packets({ sim, geo }: { sim: Sim; geo: Layout }) {
  return (
    <g>
      {sim.packets.map((packet) => {
        const [a, b] = packetEnds(sim, geo, packet);
        const lost = isLost(sim, packet);
        const bend = packet.tone === "reply" || packet.tone === "refused" ? -26 : 26;
        const c = curve(a, b, bend);
        const progress = Math.min(Math.max((sim.now - packet.sentAt) / (packet.arriveAt - packet.sentAt), 0), 1);
        const p = c.at(lost ? Math.min(progress, 0.65) : progress);
        const color = TONE_COLOR[lost ? "lost" : packet.tone];
        const label = `${lost ? "✕ " : ""}${packet.label}`;
        const width = Math.min(label.length * 6.2 + 14, 220);
        return (
          <g key={packet.id}>
            <path d={c.d} fill="none" stroke={color} strokeOpacity={0.25} strokeWidth={1.5} strokeDasharray="2 5" />
            <circle cx={p.x} cy={p.y} r={7} fill={color} filter="url(#glow)" />
            <g transform={`translate(${p.x} ${p.y - 18})`}>
              <rect x={-width / 2} y={-10} width={width} height={18} rx={9} fill={color} />
              <text y={3} textAnchor="middle" fontSize={10} fontWeight={600} fill="white">
                {truncate(label, 34)}
              </text>
            </g>
          </g>
        );
      })}
    </g>
  );
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

// ---------- Overlay pieces ----------

function PeopleDock({ sim, onDrag, onAdd }: { sim: Sim; onDrag: (e: ReactPointerEvent, d: NonNullable<Drag>) => void; onAdd: () => void }) {
  return (
    <div className="absolute top-3 left-3 flex items-center gap-1.5 rounded-full bg-kumo-elevated px-2 py-1.5 shadow ring ring-kumo-line">
      <Text size="xs" variant="secondary">
        People
      </Text>
      {sim.people.map((person) => (
        <div
          key={person.id}
          title={`Drag ${person.name} onto a device to sign in`}
          onPointerDown={(event) => onDrag(event, { kind: "person", personId: person.id, at: { x: -100, y: -100 } })}
          className="flex h-7 cursor-grab items-center gap-1 rounded-full px-2 text-xs font-semibold text-white active:cursor-grabbing"
          style={{ background: personColor(sim, person.id) }}
        >
          {person.name}
        </div>
      ))}
      <button title="Add a person" onClick={onAdd} className="flex h-7 w-7 items-center justify-center rounded-full ring ring-kumo-line hover:ring-kumo-brand">
        <PlusIcon size={12} />
      </button>
    </div>
  );
}

function AddDock({ onPhone, onBrowser, onMac }: { onPhone: () => void; onBrowser: () => void; onMac: () => void }) {
  const item = (icon: ReactNode, label: string, onClick: () => void) => (
    <button onClick={onClick} className="flex items-center gap-1 rounded-full px-2.5 py-1 text-xs hover:bg-kumo-tint">
      <PlusIcon size={10} />
      {icon}
      {label}
    </button>
  );
  return (
    <div className="absolute bottom-3 left-3 flex items-center gap-0.5 rounded-full bg-kumo-elevated p-1 shadow ring ring-kumo-line">
      {item(<DeviceMobileIcon size={14} />, "phone", onPhone)}
      {item(<DesktopIcon size={14} />, "browser", onBrowser)}
      {item(<LaptopIcon size={14} />, "Mac", onMac)}
    </div>
  );
}

function Proposals({ sim, apply }: { sim: Sim; apply: (command: Command) => void }) {
  return (
    <div className="absolute top-3 right-3 flex flex-col gap-1.5 rounded-xl bg-kumo-elevated px-3 py-2 shadow ring ring-kumo-line">
      <Text size="xs" bold>
        Try a proposed change
      </Text>
      <Switch size="sm" label="Unlink button on Macs" checked={sim.flags.unlink} onCheckedChange={(on: boolean) => apply({ t: "setFlag", flag: "unlink", value: on })} />
      <Switch size="sm" label="At most 3 waiting codes" checked={sim.flags.codeCap} onCheckedChange={(on: boolean) => apply({ t: "setFlag", flag: "codeCap", value: on })} />
    </div>
  );
}

function Tickets({ sim, client, at, onDrag }: { sim: Sim; client: Client; at: Point; onDrag: (e: ReactPointerEvent, d: NonNullable<Drag>) => void }) {
  const used = new Set(sim.relay.codes.filter((c) => c.usedBy).map((c) => c.code));
  const tickets = client.codes.filter((c) => c.expiresAt > sim.now && !used.has(c.code)).slice(-2);
  return (
    <>
      {tickets.map((ticket, i) => (
        <motion.div
          key={ticket.code}
          initial={{ scale: 0.4, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          className="absolute -translate-y-1/2"
          style={{ ...pct({ x: at.x + NODE_R + 14, y: at.y - 12 + i * 30 }) }}
        >
          <div
            title="Drag this code onto a Mac"
            onPointerDown={(event) => onDrag(event, { kind: "ticket", code: ticket.code, at: { x: -100, y: -100 } })}
            className="flex cursor-grab items-center gap-1 rounded-md border-2 border-dashed border-amber-500 bg-amber-100 px-2 py-0.5 font-mono text-xs font-bold text-amber-900 shadow active:cursor-grabbing"
          >
            <TicketIcon size={14} /> {ticket.code}
            <span className="font-sans text-[10px] font-normal opacity-70">{formatDuration(ticket.expiresAt - sim.now)}</span>
          </div>
        </motion.div>
      ))}
    </>
  );
}

function DragGhost({ sim, drag }: { sim: Sim; drag: NonNullable<Drag> }) {
  if (drag.at.x < 0) return null;
  return (
    <div className="pointer-events-none absolute -translate-x-1/2 -translate-y-1/2" style={pct(drag.at)}>
      {drag.kind === "person" ? (
        <div className="rounded-full px-3 py-1 text-xs font-bold text-white shadow-lg" style={{ background: personColor(sim, drag.personId) }}>
          {personName(sim, drag.personId)}
        </div>
      ) : (
        <div className="rounded-md border-2 border-dashed border-amber-500 bg-amber-100 px-2 py-0.5 font-mono text-xs font-bold text-amber-900 shadow-lg">
          🎟 {drag.code}
        </div>
      )}
    </div>
  );
}

function TerminalBubble({ at, side, title, lines, onRun, onClose }: { at: Point; side: "left" | "right"; title: string; lines: string[]; onRun: (c: string) => void; onClose: () => void }) {
  // Below the node, kept inside the canvas.
  const x = side === "right" ? Math.max(at.x - 110, 8) : Math.min(at.x - 100, W - 200);
  return (
    <motion.div
      initial={{ opacity: 0, y: 6 }}
      animate={{ opacity: 1, y: 0 }}
      className="absolute z-20 w-52 rounded-lg bg-black/90 p-2 shadow-xl ring ring-white/10"
      style={pct({ x, y: at.y + NODE_R + 38 })}
    >
      <div className="mb-1 flex items-center justify-between text-[10px] text-white/60">
        <span>{title}</span>
        <button onClick={onClose} aria-label="Close terminal">
          <XIcon size={10} />
        </button>
      </div>
      <pre className="m-0 h-12 overflow-hidden font-mono text-[10px] leading-4 text-green-300">{lines.slice(-3).join("\n") || " "}</pre>
      <div className="mt-1 flex gap-1">
        {COMMANDS.map((command) => (
          <button key={command} onClick={() => onRun(command)} className="rounded bg-white/10 px-1.5 py-0.5 font-mono text-[10px] text-white hover:bg-white/20">
            {command}
          </button>
        ))}
      </div>
    </motion.div>
  );
}

const BUBBLE_TONE: Record<LogEntry["tone"], string> = {
  action: "ring-kumo-line",
  request: "ring-blue-500",
  reply: "ring-green-500",
  refused: "ring-orange-500",
  stream: "ring-purple-500",
  lost: "ring-red-500",
  timer: "ring-kumo-line",
};

function SpeechBubble({ sim, geo, bubble }: { sim: Sim; geo: Layout; bubble: Bubble }) {
  if (bubble.node === "you") return null;
  const node = bubble.node;
  let at: Point;
  let align: "left" | "right" | "center" = "center";
  if (node === "relay") at = { x: RELAY.x, y: RELAY.y - 52 };
  else if (node === "access") at = { x: ACCESS.x, y: ACCESS.y - 58 };
  else if (node.startsWith("client:")) {
    const p = geo.clients.get(node.slice(7));
    if (!p) return null;
    at = { x: p.x - NODE_R + 4, y: p.y - NODE_R - (p === undefined ? 0 : 50) };
    align = "left";
  } else {
    const p = geo.macs.get(node.slice(4));
    if (!p) return null;
    at = { x: p.x + NODE_R + 40, y: p.y - NODE_R - 50 };
    align = "right";
  }
  const translate = align === "center" ? "-translate-x-1/2" : align === "right" ? "-translate-x-full" : "";
  return (
    <motion.div
      initial={{ opacity: 0, y: 6, scale: 0.95 }}
      animate={{ opacity: 1, y: 0, scale: 1 }}
      exit={{ opacity: 0 }}
      className={`pointer-events-none absolute -translate-y-full ${translate} w-max max-w-64 rounded-xl bg-kumo-elevated px-2.5 py-1.5 text-[11px] leading-snug shadow-lg ring-2 ${BUBBLE_TONE[bubble.tone]}`}
      style={pct(at)}
    >
      {bubble.tone === "timer" ? "⏱ " : ""}
      {bubble.text}
      <span className="sr-only">{sim.now}</span>
    </motion.div>
  );
}

function ActionBar({
  sim,
  geo,
  selection,
  apply,
  terminals,
  toggleTerminal,
  startPicking,
  close,
}: {
  sim: Sim;
  geo: Layout;
  selection: NonNullable<Selection>;
  apply: (command: Command) => void;
  terminals: Set<string>;
  toggleTerminal: (key: string) => void;
  startPicking: (clientId: string) => void;
  close: () => void;
}) {
  let at: Point;
  let buttons: ReactNode;
  if (selection.kind === "client") {
    const client = sim.clients.find((c) => c.id === selection.id);
    if (!client) return null;
    at = geo.clients.get(client.id)!;
    buttons = client.signedInAs ? (
      <>
        <Button size="xs" icon={<TicketIcon size={12} />} onClick={() => apply({ t: "createCode", client: client.id })}>
          Pair a host
        </Button>
        <Button size="xs" icon={<LinkIcon size={12} />} onClick={() => startPicking(client.id)}>
          Open a Mac…
        </Button>
        {client.attached && (
          <Button size="xs" icon={<TerminalWindowIcon size={12} />} onClick={() => toggleTerminal(`client:${client.id}`)}>
            {terminals.has(`client:${client.id}`) ? "Hide" : "Show"} terminal
          </Button>
        )}
        <Button size="xs" variant="ghost" icon={<SignOutIcon size={12} />} onClick={() => apply({ t: "signOut", client: client.id })}>
          Sign out
        </Button>
      </>
    ) : (
      <>
        <Text size="xs" variant="secondary">
          Drag a person here, or
        </Text>
        <Button size="xs" onClick={() => apply({ t: "listHosts", client: client.id })}>
          try without signing in
        </Button>
      </>
    );
  } else if (selection.kind === "mac") {
    const mac = sim.macs.find((m) => m.id === selection.id);
    if (!mac) return null;
    at = geo.macs.get(mac.id)!;
    buttons = (
      <>
        <Button
          size="xs"
          variant={mac.online ? "secondary" : "destructive"}
          icon={mac.online ? <WifiSlashIcon size={12} /> : <WifiHighIcon size={12} />}
          onClick={() => apply({ t: "setNetwork", mac: mac.id, online: !mac.online })}
        >
          {mac.online ? "Cut Wi-Fi" : "Restore Wi-Fi"}
        </Button>
        <Button size="xs" icon={<ArrowCounterClockwiseIcon size={12} />} onClick={() => apply({ t: "restart", mac: mac.id })}>
          Restart axod
        </Button>
        <Button size="xs" icon={<TerminalWindowIcon size={12} />} onClick={() => toggleTerminal(`mac:${mac.id}`)}>
          Terminal
        </Button>
        {mac.state === "disconnected" && (
          <Button size="xs" onClick={() => apply({ t: "retry", mac: mac.id })}>
            Retry now
          </Button>
        )}
        {sim.flags.unlink && mac.db.account && (
          <Button size="xs" variant="secondary-destructive" icon={<TrashIcon size={12} />} onClick={() => apply({ t: "unlink", mac: mac.id })}>
            Unlink
          </Button>
        )}
      </>
    );
  } else {
    const entry = geo.accounts.find((a) => a.account.id === selection.account);
    const host = entry?.account.hosts[selection.hostId];
    if (!entry || !host) return null;
    at = { x: BUBBLE.x + BUBBLE.w / 2, y: entry.hosts.get(host.hostId)!.y - 26 };
    const owner = sim.clients.find((c) => c.signedInAs === entry.account.person);
    buttons = owner ? (
      <Button size="xs" variant="destructive" disabled={host.revoked} onClick={() => apply({ t: "revoke", client: owner.id, hostId: host.hostId })}>
        Revoke {host.label} (from {owner.name})
      </Button>
    ) : (
      <Text size="xs" variant="secondary">
        Sign {personName(sim, entry.account.person)} in on a device to revoke this Mac.
      </Text>
    );
  }
  const above = true;
  return (
    <motion.div
      initial={{ opacity: 0, scale: 0.95 }}
      animate={{ opacity: 1, scale: 1 }}
      className={`absolute z-30 flex -translate-x-1/2 items-center gap-1 rounded-full bg-kumo-elevated p-1 pl-2 shadow-xl ring ring-kumo-brand ${above ? "-translate-y-full" : ""}`}
      style={pct({ x: Math.min(Math.max(at.x, 200), W - 200), y: selection.kind === "host" ? at.y : at.y - NODE_R - 10 })}
    >
      {buttons}
      <button aria-label="Close" onClick={close} className="px-1.5 text-kumo-subtle">
        <XIcon size={12} />
      </button>
    </motion.div>
  );
}

function Transport({
  model,
  setModel,
  speed,
  setSpeed,
  apply,
  onReset,
}: {
  model: Model;
  setModel: (f: (m: Model) => Model) => void;
  speed: string;
  setSpeed: (s: string) => void;
  apply: (command: Command) => void;
  onReset: () => void;
}) {
  const { sim, mode } = model;
  const next = nextEventAt(sim);
  return (
    <div className="absolute bottom-3 left-1/2 flex -translate-x-1/2 items-center gap-1 rounded-full bg-kumo-elevated p-1 shadow-lg ring ring-kumo-line">
      <span className="px-2 font-mono text-xs tabular-nums">{formatTime(sim.now)}</span>
      <Button
        size="xs"
        variant="ghost"
        shape="square"
        aria-label="Back"
        icon={<ArrowLeftIcon size={12} />}
        disabled={model.history.length === 0}
        onClick={() => setModel((m) => ({ ...m, sim: m.history.at(-1)!, history: m.history.slice(0, -1), mode: "paused" }))}
      />
      <Button
        size="xs"
        variant={mode === "playing" ? "secondary" : "primary"}
        icon={mode === "playing" ? <PauseIcon size={12} /> : <PlayIcon size={12} />}
        onClick={() => setModel((m) => ({ ...m, mode: m.mode === "playing" ? "paused" : "playing" }))}
      >
        {mode === "playing" ? "Pause" : "Play"}
      </Button>
      <Button
        size="xs"
        variant="ghost"
        icon={<SkipForwardIcon size={12} />}
        disabled={next === null || mode !== "paused"}
        onClick={() => setModel((m) => ({ ...m, mode: "stepping", stepFrom: m.sim.now, stepTo: nextEventAt(m.sim) ?? m.sim.now }))}
      >
        Step
      </Button>
      <Tabs
        size="sm"
        value={speed}
        onValueChange={setSpeed}
        tabs={[
          { value: "0.25", label: "¼×" },
          { value: "1", label: "1×" },
          { value: "5", label: "5×" },
          { value: "25", label: "25×" },
        ]}
      />
      <Button size="xs" variant="ghost" icon={<FastForwardIcon size={12} />} onClick={() => apply({ t: "skip", by: 10 * 60 * 1000 })}>
        10 min
      </Button>
      <Button size="xs" variant="ghost" shape="square" aria-label="Reset" icon={<ArrowCounterClockwiseIcon size={12} />} onClick={onReset} />
    </div>
  );
}

/** Suggests the next interesting thing to do, from the current state. */
function Hint({ sim, picking }: { sim: Sim; picking: Picking }) {
  let text: string;
  const signedIn = sim.clients.filter((c) => c.signedInAs);
  const tickets = sim.clients.some((c) => c.codes.some((k) => k.expiresAt > sim.now && !sim.relay.codes.find((r) => r.code === k.code)?.usedBy));
  const linked = sim.macs.filter((m) => m.state === "connected");
  const watching = sim.clients.some((c) => c.attached);
  if (picking) text = "Now click the Mac to open. Press Esc to cancel.";
  else if (sim.clients.length === 0) text = "Add a phone or a browser (bottom left).";
  else if (sim.macs.length === 0) text = "Add a Mac (bottom left).";
  else if (signedIn.length === 0) text = "Drag a person from the top-left onto a device to sign in through Access.";
  else if (tickets) text = "Drag the yellow ticket onto a Mac to pair it.";
  else if (linked.length === 0) text = "Click a signed-in device, then “Pair a host” to get a pairing code.";
  else if (!watching) text = "Click a signed-in device, then “Open a Mac…”, then click the Mac.";
  else text = "Run a command in the terminal bubble. Then try: cut a Mac's Wi-Fi, restart axod, revoke a Mac in the cloud, or sign someone else in.";
  return (
    <motion.div key={text} initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }} className="flex items-center gap-2 rounded-full bg-kumo-tint px-3 py-1.5 text-sm">
      <span>👉</span>
      {text}
    </motion.div>
  );
}
