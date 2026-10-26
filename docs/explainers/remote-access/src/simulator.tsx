import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Button } from "@cloudflare/kumo/components/button";
import { Input } from "@cloudflare/kumo/components/input";
import { LayerCard } from "@cloudflare/kumo/components/layer-card";
import { Select } from "@cloudflare/kumo/components/select";
import { Switch } from "@cloudflare/kumo/components/switch";
import { Tabs } from "@cloudflare/kumo/components/tabs";
import { Text } from "@cloudflare/kumo/components/text";
import {
  ArrowCounterClockwiseIcon,
  ArrowLeftIcon,
  ClockIcon,
  CloudIcon,
  DesktopIcon,
  DeviceMobileIcon,
  FastForwardIcon,
  KeyIcon,
  LaptopIcon,
  PauseIcon,
  PlayIcon,
  PlusIcon,
  ShieldCheckIcon,
  SkipForwardIcon,
  TrashIcon,
  WifiHighIcon,
  WifiSlashIcon,
} from "@phosphor-icons/react";
import {
  addClient,
  addMac,
  addPerson,
  advance,
  clientActions,
  clientName,
  hostLabel,
  hostStatus,
  macActions,
  nextEventAt,
  nodeName,
  personName,
  presets,
  setFlag,
  skip,
  type Client,
  type ConnectionState,
  type HostStatus,
  type LogEntry,
  type Mac,
  type NodeId,
  type Packet,
  type Sim,
  type Tone,
} from "./sim";

export type Mode = "paused" | "playing" | "stepping";
export type Model = { sim: Sim; history: Sim[]; mode: Mode; stepFrom: number; stepTo: number };

export const STEP_ANIMATION_MS = 450;
export { HISTORY } from "./replay";
import { HISTORY } from "./replay";
const MAC_NAMES = ["Studio", "MacBook", "Mac mini", "iMac", "Mac Pro", "Work MacBook"];
const PEOPLE = ["Alice", "Bob", "Carol", "Dan", "Erin"];

export function Simulator() {
  const [model, setModel] = useState<Model>(() => ({
    sim: presetFromHash().build(),
    history: [],
    mode: "paused",
    stepFrom: 0,
    stepTo: 0,
  }));
  const [speed, setSpeed] = useState("1");
  const { sim } = model;

  const apply = (change: (sim: Sim) => Sim) =>
    setModel((m) => ({ ...m, sim: change(m.sim), history: [...m.history, m.sim].slice(-HISTORY) }));

  useAnimation(model, setModel, Number(speed));

  const next = nextEventAt(sim);
  const step = () =>
    setModel((m) => {
      const at = nextEventAt(m.sim);
      return at === null ? m : { ...m, mode: "stepping", stepFrom: m.sim.now, stepTo: at };
    });

  return (
    <div className="flex flex-col gap-4">
      <Text variant="secondary">
        A working model of the whole system. Add people, phones, browsers and Macs; press buttons on
        them like a user would; then step through every message and timer and watch what each part
        remembers. Nothing here touches a real network: it's the same rules, simulated.
      </Text>

      <LayerCard>
        <LayerCard.Primary className="flex flex-col gap-3">
          <div className="flex flex-wrap items-end gap-2">
            <Select
              label="Start from"
              size="sm"
              className="w-56"
              placeholder="Choose a preset"
              onValueChange={(value: unknown) => {
                const preset = presets.find((p) => p.id === value);
                if (!preset) return;
                history.replaceState(null, "", `#sim/${preset.id}`);
                setModel({ sim: preset.build(), history: [], mode: "paused", stepFrom: 0, stepTo: 0 });
              }}
              items={Object.fromEntries(presets.map((p) => [p.id, p.name]))}
            />
            <AddControls sim={sim} apply={apply} />
            <div className="ml-auto flex flex-wrap items-center gap-4">
              <Switch
                size="sm"
                label="Proposed: Unlink button"
                checked={sim.flags.unlink}
                onCheckedChange={(on: boolean) => apply((s) => setFlag(s, "unlink", on))}
              />
              <Switch
                size="sm"
                label="Proposed: cap of 3 waiting codes"
                checked={sim.flags.codeCap}
                onCheckedChange={(on: boolean) => apply((s) => setFlag(s, "codeCap", on))}
              />
            </div>
          </div>
          {(sim.flags.unlink || sim.flags.codeCap) && (
            <div className="flex flex-col gap-0.5 rounded-md bg-kumo-recessed px-3 py-2">
              <Text size="xs" bold>
                Proposed changes in effect (not built yet)
              </Text>
              {sim.flags.unlink && (
                <Text variant="secondary" size="xs">
                  Unlink: each linked Mac gets an Unlink button. axod says goodbye to the relay, clears
                  host_link and deletes its Keychain secret. The relay keeps the host record (offline)
                  until you revoke it.
                </Text>
              )}
              {sim.flags.codeCap && (
                <Text variant="secondary" size="xs">
                  Code cap (G6): an account may have at most 3 unused, unexpired pairing codes; a fourth
                  Pair a host gets 429.
                </Text>
              )}
            </div>
          )}
          <div className="flex flex-wrap items-center gap-2 border-t border-kumo-line pt-3">
            <Badge variant="outline" icon={<ClockIcon size={12} />}>
              t = {formatTime(sim.now)}
            </Badge>
            <Text variant="secondary" size="sm">
              {next === null ? "nothing scheduled" : `next event in ${formatDuration(next - sim.now)}`}
            </Text>
            <div className="ml-auto flex flex-wrap items-center gap-2">
              <Button
                size="sm"
                icon={<ArrowLeftIcon size={14} />}
                disabled={model.history.length === 0}
                onClick={() =>
                  setModel((m) => ({ ...m, sim: m.history.at(-1)!, history: m.history.slice(0, -1), mode: "paused" }))
                }
              >
                Back
              </Button>
              <Button size="sm" variant="primary" icon={<SkipForwardIcon size={14} />} disabled={next === null || model.mode !== "paused"} onClick={step}>
                Step
              </Button>
              <Button
                size="sm"
                icon={model.mode === "playing" ? <PauseIcon size={14} /> : <PlayIcon size={14} />}
                disabled={next === null && model.mode !== "playing"}
                onClick={() => setModel((m) => ({ ...m, mode: m.mode === "playing" ? "paused" : "playing" }))}
              >
                {model.mode === "playing" ? "Pause" : "Play"}
              </Button>
              <Tabs
                size="sm"
                value={speed}
                onValueChange={setSpeed}
                tabs={[
                  { value: "0.5", label: "½×" },
                  { value: "1", label: "1×" },
                  { value: "5", label: "5×" },
                  { value: "25", label: "25×" },
                ]}
              />
              <Button size="sm" variant="ghost" icon={<FastForwardIcon size={14} />} onClick={() => apply((s) => skip(s, 10 * 60 * 1000))}>
                +10 min
              </Button>
              <Button
                size="sm"
                variant="ghost"
                icon={<ArrowCounterClockwiseIcon size={14} />}
                onClick={() => setModel({ sim: presets[0]!.build(), history: [], mode: "paused", stepFrom: 0, stepTo: 0 })}
              >
                Reset
              </Button>
            </div>
          </div>
        </LayerCard.Primary>
      </LayerCard>

      <Board sim={sim} apply={apply} />

      <div className="grid gap-4 lg:grid-cols-[2fr_1fr]">
        <EventLog sim={sim} />
        <Upcoming sim={sim} />
      </div>
    </div>
  );
}

/** `#sim/family` starts from the "Two people, three Macs" preset. */
function presetFromHash() {
  const id = location.hash.split("/")[1];
  return presets.find((p) => p.id === id) ?? presets[0]!;
}

export function useAnimation(model: Model, setModel: (f: (m: Model) => Model) => void, speed: number, live = false) {
  const running = model.mode !== "paused";
  useEffect(() => {
    if (!running) return;
    let last = performance.now();
    let frame = requestAnimationFrame(function tick(t) {
      const dt = Math.min(t - last, 100);
      last = t;
      setModel((m) => {
        if (m.mode === "stepping") {
          const rate = Math.max((m.stepTo - m.stepFrom) / STEP_ANIMATION_MS, 0.001);
          const now = Math.min(m.sim.now + rate * dt, m.stepTo);
          if (now < m.stepTo) return { ...m, sim: { ...m.sim, now } };
          const { sim } = advance(m.sim, m.stepTo, 1);
          return { ...m, sim, history: [...m.history, m.sim].slice(-HISTORY), mode: "paused" };
        }
        if (m.mode === "playing") {
          if (!live && nextEventAt(m.sim) === null) return { ...m, mode: "paused" };
          const { sim, ran } = advance(m.sim, m.sim.now + dt * speed, 50);
          return ran ? { ...m, sim, history: [...m.history, m.sim].slice(-HISTORY) } : { ...m, sim };
        }
        return m;
      });
      frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, [running, speed, setModel, live]);
}

function AddControls({ sim, apply }: { sim: Sim; apply: (f: (s: Sim) => Sim) => void }) {
  const [owner, setOwner] = useState<string | null>(null);
  const ownerId = owner && sim.people.some((p) => p.id === owner) ? owner : sim.people[0]?.id ?? null;
  const nextMac = MAC_NAMES.find((n) => !sim.macs.some((m) => m.name === n)) ?? `Mac ${sim.macs.length + 1}`;
  const nextPerson = PEOPLE.find((n) => !sim.people.some((p) => p.name === n)) ?? `Person ${sim.people.length + 1}`;
  return (
    <div className="flex flex-wrap items-end gap-2">
      <Button size="sm" icon={<PlusIcon size={14} />} onClick={() => apply((s) => addMac(s, nextMac))}>
        Mac
      </Button>
      <Button size="sm" icon={<PlusIcon size={14} />} onClick={() => apply((s) => addPerson(s, nextPerson))}>
        Person
      </Button>
      {ownerId && (
        <>
          <Select
            aria-label="Owner of the new device"
            size="sm"
            className="w-28"
            value={ownerId}
            onValueChange={(v: unknown) => setOwner(String(v))}
            items={Object.fromEntries(sim.people.map((p) => [p.id, p.name]))}
          />
          <Button size="sm" icon={<PlusIcon size={14} />} onClick={() => apply((s) => addClient(s, "phone", ownerId))}>
            phone
          </Button>
          <Button size="sm" icon={<PlusIcon size={14} />} onClick={() => apply((s) => addClient(s, "browser", ownerId))}>
            browser
          </Button>
        </>
      )}
    </div>
  );
}

// ---------- The board ----------

function Board({ sim, apply }: { sim: Sim; apply: (f: (s: Sim) => Sim) => void }) {
  const board = useRef<HTMLDivElement>(null);
  return (
    <div ref={board} className="relative grid items-start gap-x-16 gap-y-4 lg:grid-cols-[1fr_1.15fr_1fr]">
      <Column title="People's devices" hint="never paired; they sign in with Access">
        {sim.clients.length === 0 && <Empty>Add a phone or a browser.</Empty>}
        {sim.clients.map((client) => (
          <ClientCard key={client.id} sim={sim} client={client} apply={apply} />
        ))}
      </Column>
      <Column title="Cloudflare" hint="Access checks people; the relay connects things">
        <AccessCard sim={sim} />
        <RelayCard sim={sim} />
      </Column>
      <Column title="Macs" hint="each runs axod; paired once with a code">
        {sim.macs.length === 0 && <Empty>Add a Mac.</Empty>}
        {sim.macs.map((mac) => (
          <MacCard key={mac.id} sim={sim} mac={mac} apply={apply} />
        ))}
      </Column>
      <Wires sim={sim} board={board} />
    </div>
  );
}

function Column({ title, hint, children }: { title: string; hint: string; children: ReactNode }) {
  return (
    <div className="relative z-10 flex flex-col gap-3">
      <div>
        <Text bold>{title}</Text>
        <Text variant="secondary" size="xs">
          {hint}
        </Text>
      </div>
      {children}
    </div>
  );
}

function Empty({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-xl border border-dashed border-kumo-line p-6 text-center">
      <Text variant="secondary" size="sm">
        {children}
      </Text>
    </div>
  );
}

const TONE_CLASS: Record<Tone, string> = {
  request: "bg-kumo-brand text-white",
  reply: "bg-green-600 text-white",
  refused: "bg-orange-600 text-white",
  stream: "bg-purple-600 text-white",
  lost: "bg-red-600 text-white",
};

/** Lines for open sockets and pills for packets in flight, positioned from the cards' boxes. */
function Wires({ sim, board }: { sim: Sim; board: React.RefObject<HTMLDivElement | null> }) {
  const svg = useRef<SVGSVGElement>(null);
  const pills = useRef(new Map<number, HTMLDivElement>());

  const sockets: { from: NodeId; to: NodeId; tone: "host" | "viewer" }[] = [];
  for (const mac of sim.macs) if (mac.socketOpen) sockets.push({ from: `mac:${mac.id}`, to: "relay", tone: "host" });
  for (const account of Object.values(sim.relay.accounts)) {
    for (const host of Object.values(account.hosts)) {
      for (const viewer of host.clients) sockets.push({ from: `client:${viewer}`, to: "relay", tone: "viewer" });
    }
  }

  useLayoutEffect(() => {
    const root = board.current;
    if (!root) return;
    const origin = root.getBoundingClientRect();
    const anchor = (node: NodeId, peer: NodeId) => {
      const element = root.querySelector(`[data-node="${node}"]`);
      if (!element) return null;
      const box = element.getBoundingClientRect();
      const x = box.left - origin.left;
      const y = box.top - origin.top;
      if (node.startsWith("client:")) return { x: x + box.width, y: y + 28 };
      if (node.startsWith("mac:")) return { x, y: y + 28 };
      if (node === "access" && peer === "relay") return { x: x + box.width / 2, y: y + box.height };
      if (node === "relay" && peer === "access") return { x: x + box.width / 2, y };
      const side = peer.startsWith("mac:") ? x + box.width : x;
      return { x: side, y: y + Math.min(box.height / 2, 60) };
    };

    const lines = svg.current;
    if (lines) {
      lines.innerHTML = "";
      for (const socket of sockets) {
        const a = anchor(socket.from, socket.to);
        const b = anchor(socket.to, socket.from);
        if (!a || !b) continue;
        const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
        line.setAttribute("x1", `${a.x}`);
        line.setAttribute("y1", `${a.y}`);
        line.setAttribute("x2", `${b.x}`);
        line.setAttribute("y2", `${b.y}`);
        line.setAttribute("stroke", socket.tone === "host" ? "#16a34a" : "#9333ea");
        line.setAttribute("stroke-width", "2");
        line.setAttribute("stroke-dasharray", socket.tone === "host" ? "0" : "5 4");
        line.setAttribute("opacity", "0.6");
        lines.appendChild(line);
      }
    }

    for (const packet of sim.packets) {
      const pill = pills.current.get(packet.id);
      const a = anchor(packet.from, packet.to);
      const b = anchor(packet.to, packet.from);
      if (!pill || !a || !b) continue;
      const progress = Math.min(Math.max((sim.now - packet.sentAt) / (packet.arriveAt - packet.sentAt), 0), 1);
      const shown = isLost(sim, packet) ? Math.min(progress, 0.7) : progress;
      pill.style.left = `${a.x + (b.x - a.x) * shown}px`;
      pill.style.top = `${a.y + (b.y - a.y) * shown}px`;
    }
  });

  return (
    <div className="pointer-events-none absolute inset-0 z-20 hidden lg:block">
      <svg ref={svg} className="absolute inset-0 h-full w-full overflow-visible" />
      {sim.packets.map((packet) => (
        <div
          key={packet.id}
          ref={(element) => {
            if (element) pills.current.set(packet.id, element);
            else pills.current.delete(packet.id);
          }}
          className="absolute -translate-x-1/2 -translate-y-1/2"
        >
          <div className={`whitespace-nowrap rounded-full px-2.5 py-0.5 text-[11px] font-medium shadow-lg ${TONE_CLASS[isLost(sim, packet) ? "lost" : packet.tone]}`}>
            {isLost(sim, packet) ? "✕ " : ""}
            {packet.label}
          </div>
        </div>
      ))}
    </div>
  );
}

function isLost(sim: Sim, packet: Packet): boolean {
  if (packet.lost) return true;
  if (!packet.to.startsWith("mac:")) return false;
  const mac = sim.macs.find((m) => `mac:${m.id}` === packet.to);
  return !mac || !mac.online;
}

// ---------- Cards ----------

function Card({ node, icon, title, badge, children }: { node: NodeId; icon: ReactNode; title: ReactNode; badge?: ReactNode; children: ReactNode }) {
  return (
    <div data-node={node}>
      <LayerCard>
        <LayerCard.Secondary className="flex items-center justify-between gap-2">
          <span className="flex min-w-0 items-center gap-2">
            {icon}
            <span className="truncate">{title}</span>
          </span>
          {badge}
        </LayerCard.Secondary>
        <LayerCard.Primary className="flex flex-col gap-3 p-3">{children}</LayerCard.Primary>
      </LayerCard>
    </div>
  );
}

function ClientCard({ sim, client, apply }: { sim: Sim; client: Client; apply: (f: (s: Sim) => Sim) => void }) {
  const [person, setPerson] = useState(client.owner);
  const [command, setCommand] = useState("ls");
  const act = (f: (s: Sim) => Sim) => apply(f);
  return (
    <Card
      node={`client:${client.id}`}
      icon={client.kind === "phone" ? <DeviceMobileIcon size={16} /> : <DesktopIcon size={16} />}
      title={client.name}
      badge={
        client.signedInAs ? <Badge variant="success">{personName(sim, client.signedInAs)}</Badge> : <Badge variant="neutral">signed out</Badge>
      }
    >
      {!client.signedInAs ? (
        <div className="flex items-end gap-2">
          <Select
            aria-label="Sign in as"
            size="sm"
            className="w-28"
            value={person}
            onValueChange={(v: unknown) => setPerson(String(v))}
            items={Object.fromEntries(sim.people.map((p) => [p.id, p.name]))}
          />
          <Button size="sm" variant="primary" onClick={() => act((s) => clientActions.signIn(s, client.id, person))}>
            Sign in
          </Button>
          <Button size="sm" variant="ghost" onClick={() => act((s) => clientActions.listHosts(s, client.id))}>
            Try without signing in
          </Button>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <Button size="sm" onClick={() => act((s) => clientActions.createCode(s, client.id))}>
            Pair a host
          </Button>
          <Button size="sm" variant="ghost" onClick={() => act((s) => clientActions.listHosts(s, client.id))}>
            Refresh
          </Button>
          <Button size="sm" variant="ghost" onClick={() => act((s) => clientActions.signOut(s, client.id))}>
            Sign out
          </Button>
        </div>
      )}

      {client.codes.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {client.codes.slice(-3).map((code) => (
            <Badge key={code.code} variant={code.expiresAt > sim.now ? "warning" : "neutral"}>
              {code.code} · {code.expiresAt > sim.now ? formatDuration(code.expiresAt - sim.now) : "expired"}
            </Badge>
          ))}
        </div>
      )}

      {client.hosts && (
        <div className="flex flex-col gap-1">
          {client.hosts.length === 0 && (
            <Text variant="secondary" size="sm">
              No hosts in this account.
            </Text>
          )}
          {client.hosts.map((host) => (
            <div key={host.hostId} className="flex items-center justify-between gap-2 rounded-md bg-kumo-recessed px-2 py-1">
              <span className="flex items-center gap-2">
                <StatusDot status={host.status} />
                <Text size="sm">{host.label}</Text>
              </span>
              <span className="flex gap-1">
                {client.attached === host.hostId ? (
                  <Button size="xs" variant="ghost" onClick={() => act((s) => clientActions.leave(s, client.id))}>
                    Close
                  </Button>
                ) : (
                  <Button size="xs" onClick={() => act((s) => clientActions.open(s, client.id, host.hostId))}>
                    Open
                  </Button>
                )}
                <Button size="xs" variant="secondary-destructive" disabled={host.status === "revoked"} onClick={() => act((s) => clientActions.revoke(s, client.id, host.hostId))}>
                  Revoke
                </Button>
              </span>
            </div>
          ))}
        </div>
      )}

      {client.signedInAs && <StrangerTry sim={sim} client={client} apply={apply} />}

      {client.attached && (
        <Terminal
          title={`watching ${hostLabel(sim, client.attached)}`}
          lines={client.terminal}
          command={command}
          setCommand={setCommand}
          onRun={(text) => act((s) => clientActions.type(s, client.id, text))}
        />
      )}
      {client.lastError && <ErrorLine text={client.lastError} />}
    </Card>
  );
}

/** Lets you try to open a Mac that belongs to someone else, to see the relay refuse. */
function StrangerTry({ sim, client, apply }: { sim: Sim; client: Client; apply: (f: (s: Sim) => Sim) => void }) {
  const mine = new Set(client.hosts?.map((h) => h.hostId) ?? []);
  const others = sim.macs.filter((m) => m.db.account && !mine.has(m.hostId));
  if (others.length === 0) return null;
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <Text variant="secondary" size="xs">
        Try someone else's Mac:
      </Text>
      {others.map((mac) => (
        <Button key={mac.id} size="xs" variant="outline" onClick={() => apply((s) => clientActions.open(s, client.id, mac.hostId))}>
          {mac.name}
        </Button>
      ))}
    </div>
  );
}

function MacCard({ sim, mac, apply }: { sim: Sim; mac: Mac; apply: (f: (s: Sim) => Sim) => void }) {
  const [code, setCode] = useState("");
  const [command, setCommand] = useState("hostname");
  const visibleCodes = sim.clients.flatMap((c) => c.codes.filter((k) => k.expiresAt > sim.now).map((k) => k.code));
  const retry = sim.timers.find((t) => t.node === `mac:${mac.id}` && t.body.t === "retry");
  return (
    <Card
      node={`mac:${mac.id}`}
      icon={<LaptopIcon size={16} />}
      title={
        <span>
          {mac.name} <span className="text-xs text-kumo-subtle">{mac.hostId}</span>
        </span>
      }
      badge={<ConnectionBadge state={mac.state} />}
    >
      <div className="flex flex-wrap items-center gap-2">
        <Button
          size="xs"
          variant={mac.online ? "ghost" : "destructive"}
          icon={mac.online ? <WifiHighIcon size={12} /> : <WifiSlashIcon size={12} />}
          onClick={() => apply((s) => macActions.setNetwork(s, mac.id, !mac.online))}
        >
          {mac.online ? "Wi-Fi on" : "Wi-Fi off"}
        </Button>
        <Button size="xs" variant="ghost" icon={<ArrowCounterClockwiseIcon size={12} />} onClick={() => apply((s) => macActions.restart(s, mac.id))}>
          Restart axod
        </Button>
        {mac.state === "disconnected" && (
          <Button size="xs" variant="ghost" onClick={() => apply((s) => macActions.retry(s, mac.id))}>
            Retry now
          </Button>
        )}
        {sim.flags.unlink && mac.db.account && (
          <Button size="xs" variant="secondary-destructive" icon={<TrashIcon size={12} />} onClick={() => apply((s) => macActions.unlink(s, mac.id))}>
            Unlink
          </Button>
        )}
      </div>

      <form
        className="flex items-end gap-2"
        onSubmit={(event) => {
          event.preventDefault();
          apply((s) => macActions.link(s, mac.id, code));
        }}
      >
        <Input size="sm" aria-label="Pairing code" placeholder="XXXX-XXXX" value={code} onChange={(e) => setCode(e.target.value)} />
        <Button size="sm" type="submit" disabled={!code}>
          Link
        </Button>
      </form>
      {visibleCodes.length > 0 && (
        <div className="-mt-1 flex flex-wrap items-center gap-1">
          <Text variant="secondary" size="xs">
            codes on screens:
          </Text>
          {visibleCodes.map((value) => (
            <button key={value} type="button" className="rounded bg-kumo-recessed px-1.5 font-mono text-[11px] hover:ring hover:ring-kumo-brand" onClick={() => setCode(value)}>
              {value}
            </button>
          ))}
        </div>
      )}

      <div className="grid grid-cols-[3fr_2fr] gap-2">
      <Storage title="axo.db · host_link">
        <KV label="account" value={mac.db.account} />
        <KV label="credential" value={mac.db.credential} />
        <KV label="pending" value={mac.db.pending} tone="warning" />
      </Storage>
      <Storage title="Keychain">
        {mac.keychain.length === 0 ? (
          <Text variant="secondary" size="xs">
            empty
          </Text>
        ) : (
          <div className="flex flex-wrap gap-1">
            {mac.keychain.map((credential) => (
              <Badge key={credential} variant="teal" icon={<KeyIcon size={10} />}>
                {credential}
              </Badge>
            ))}
          </div>
        )}
      </Storage>
      </div>
      {retry && (
        <Text variant="secondary" size="xs">
          next try in {formatDuration(retry.at - sim.now)}
        </Text>
      )}
      {mac.lastError && <ErrorLine text={mac.lastError} />}
      <Terminal
        title="local terminal"
        lines={mac.terminal}
        command={command}
        setCommand={setCommand}
        onRun={(text) => apply((s) => macActions.type(s, mac.id, text))}
      />
    </Card>
  );
}

function AccessCard({ sim }: { sim: Sim }) {
  const sessions = Object.entries(sim.access.sessions);
  return (
    <Card node="access" icon={<ShieldCheckIcon size={16} />} title="Cloudflare Access" badge={<Badge variant="outline">people only</Badge>}>
      {sessions.length === 0 ? (
        <Text variant="secondary" size="sm">
          No one is signed in. Every request from a device passes through here first.
        </Text>
      ) : (
        sessions.map(([client, person]) => (
          <KV key={client} label={clientName(sim, client)} value={personName(sim, person)} />
        ))
      )}
      <Text variant="secondary" size="xs">
        Macs skip Access: their routes are bypassed and they prove themselves with a credential.
      </Text>
    </Card>
  );
}

function RelayCard({ sim }: { sim: Sim }) {
  const accounts = Object.values(sim.relay.accounts);
  return (
    <Card node="relay" icon={<CloudIcon size={16} />} title="Axo relay · axo.leostera.dev">
      {accounts.length === 0 && (
        <Text variant="secondary" size="sm">
          No accounts yet. An account is made the first time a signed-in person makes a request.
        </Text>
      )}
      {accounts.map((account) => (
        <Storage key={account.id} title={`${account.id} (${personName(sim, account.person)})`}>
          {Object.values(account.hosts).length === 0 && (
            <Text variant="secondary" size="xs">
              no hosts
            </Text>
          )}
          {Object.values(account.hosts).map((host) => (
            <div key={host.hostId} className="flex flex-col gap-0.5 rounded-md bg-kumo-base px-2 py-1">
              <div className="flex items-center justify-between gap-2">
                <span className="flex items-center gap-2">
                  <StatusDot status={hostStatus(host)} />
                  <Text size="sm">{host.label}</Text>
                </span>
                <Text variant="mono-secondary">verifier({host.credential})</Text>
              </div>
              {host.clients.length > 0 && (
                <Text variant="secondary" size="xs">
                  viewers: {host.clients.map((c) => clientName(sim, c)).join(", ")}
                </Text>
              )}
            </div>
          ))}
          {sim.relay.codes
            .filter((c) => c.account === account.id)
            .slice(-4)
            .map((code) => (
              <div key={code.code} className="flex items-center justify-between">
                <Text variant="mono-secondary">hmac({code.code})</Text>
                <Badge variant={code.usedBy ? "neutral" : code.expiresAt > sim.now ? "warning" : "neutral"}>
                  {code.usedBy ? `used by ${hostLabel(sim, code.usedBy.hostId)}` : code.expiresAt > sim.now ? formatDuration(code.expiresAt - sim.now) : "expired"}
                </Badge>
              </div>
            ))}
        </Storage>
      ))}
      <Text variant="secondary" size="xs">
        Stores verifiers, not secrets or codes. Passes terminal traffic along without keeping it.
      </Text>
    </Card>
  );
}

// ---------- Small pieces ----------

function Storage({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-1 rounded-lg bg-kumo-recessed p-2">
      <Text size="xs" bold>
        {title}
      </Text>
      {children}
    </div>
  );
}

function KV({ label, value, tone }: { label: string; value: string | null; tone?: "warning" }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <Text variant="secondary" size="xs">
        {label}
      </Text>
      {value ? <Badge variant={tone ?? "blue"}>{value}</Badge> : <Text variant="mono-secondary">—</Text>}
    </div>
  );
}

function ConnectionBadge({ state }: { state: ConnectionState }) {
  const variant = { "not linked": "neutral", connecting: "warning", connected: "success", disconnected: "error" } as const;
  return (
    <Badge appearance="dot" variant={variant[state]}>
      {state}
    </Badge>
  );
}

function StatusDot({ status }: { status: HostStatus }) {
  const color = { online: "bg-green-500", offline: "bg-kumo-line", revoked: "bg-red-500" }[status];
  return <span title={status} className={`inline-block h-2 w-2 rounded-full ${color}`} />;
}

function ErrorLine({ text }: { text: string }) {
  return <div className="rounded-md bg-red-500/10 px-2 py-1 text-xs text-red-600 dark:text-red-400">{text}</div>;
}

function Terminal({
  title,
  lines,
  command,
  setCommand,
  onRun,
}: {
  title: string;
  lines: string[];
  command: string;
  setCommand: (value: string) => void;
  onRun: (text: string) => void;
}) {
  return (
    <div className="flex flex-col gap-1">
      <Text variant="secondary" size="xs">
        {title}
      </Text>
      <pre className="m-0 h-14 overflow-hidden rounded-md bg-black p-2 font-mono text-[11px] leading-4 text-green-300">
        {lines.slice(-3).join("\n") || " "}
      </pre>
      <form
        className="flex gap-1"
        onSubmit={(event) => {
          event.preventDefault();
          if (command.trim()) onRun(command.trim());
        }}
      >
        <Input size="xs" aria-label="Command" value={command} onChange={(e) => setCommand(e.target.value)} />
        <Button size="xs" type="submit">
          Run
        </Button>
      </form>
    </div>
  );
}

export function EventLog({ sim }: { sim: Sim }) {
  return (
    <LayerCard>
      <LayerCard.Secondary>What happened, newest first</LayerCard.Secondary>
      <LayerCard.Primary className="flex max-h-[28rem] flex-col gap-2 overflow-auto p-3">
        {sim.log.length === 0 && (
          <Text variant="secondary" size="sm">
            Nothing yet. Press a button on a device or a Mac, then Step.
          </Text>
        )}
        {sim.log.slice(0, 80).map((entry) => (
          <LogLine key={entry.id} sim={sim} entry={entry} />
        ))}
      </LayerCard.Primary>
    </LayerCard>
  );
}

const LOG_TONE: Record<LogEntry["tone"], "primary" | "success" | "warning" | "purple" | "error" | "neutral" | "info"> = {
  action: "primary",
  request: "info",
  reply: "success",
  refused: "warning",
  stream: "purple",
  lost: "error",
  timer: "neutral",
};

function LogLine({ sim, entry }: { sim: Sim; entry: LogEntry }) {
  return (
    <div className="flex flex-col gap-1 rounded-lg bg-kumo-recessed p-2">
      <div className="flex items-start gap-2">
        <Text variant="mono-secondary">{formatTime(entry.at)}</Text>
        <Badge variant={LOG_TONE[entry.tone]}>{entry.tone === "action" ? "you" : entry.tone === "timer" ? `⏱ ${nodeName(sim, entry.node)}` : nodeName(sim, entry.node)}</Badge>
        <Text size="sm">{entry.title}</Text>
      </div>
      {entry.changes.length > 0 && (
        <div className="ml-16 flex flex-col gap-0.5">
          {entry.changes.map((change) => (
            <div key={change.key} className="font-mono text-[11px] text-kumo-subtle">
              {change.key}: <span className="line-through opacity-60">{change.before}</span> →{" "}
              <span className="text-kumo-default">{change.after}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function Upcoming({ sim }: { sim: Sim }) {
  const items = [
    ...sim.packets.map((p) => ({
      at: p.arriveAt,
      key: `p${p.id}`,
      text: `${nodeName(sim, p.from)} → ${nodeName(sim, p.to)}: ${p.label}`,
      tone: (isLost(sim, p) ? "lost" : p.tone) as LogEntry["tone"],
    })),
    ...sim.timers.map((t) => ({ at: t.at, key: `t${t.id}`, text: `${nodeName(sim, t.node)}: ${t.label}`, tone: "timer" as const })),
  ].sort((a, b) => a.at - b.at);
  return (
    <LayerCard>
      <LayerCard.Secondary>Coming up</LayerCard.Secondary>
      <LayerCard.Primary className="flex max-h-[28rem] flex-col gap-1.5 overflow-auto p-3">
        {items.length === 0 && (
          <Text variant="secondary" size="sm">
            Nothing in flight and no timers. The system is idle.
          </Text>
        )}
        {items.slice(0, 30).map((item) => (
          <div key={item.key} className="flex items-center gap-2">
            <Badge variant={LOG_TONE[item.tone]}>{item.tone === "timer" ? "timer" : item.tone === "lost" ? "lost" : "packet"}</Badge>
            <Text size="sm">{item.text}</Text>
            <span className="ml-auto whitespace-nowrap">
              <Text variant="mono-secondary">in {formatDuration(item.at - sim.now)}</Text>
            </span>
          </div>
        ))}
      </LayerCard.Primary>
    </LayerCard>
  );
}

export function formatTime(ms: number): string {
  const total = ms / 1000;
  if (total < 60) return `${total.toFixed(2)}s`;
  const minutes = Math.floor(total / 60);
  return `${minutes}m ${(total % 60).toFixed(1).padStart(4, "0")}s`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.max(0, Math.round(ms))} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  return `${Math.floor(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
}
