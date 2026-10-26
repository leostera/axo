import { useEffect, useMemo, useState, type ReactNode } from "react";
import { motion } from "motion/react";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Collapsible } from "@cloudflare/kumo/components/collapsible";
import { LayerCard } from "@cloudflare/kumo/components/layer-card";
import { Table } from "@cloudflare/kumo/components/table";
import { Tabs } from "@cloudflare/kumo/components/tabs";
import { Text } from "@cloudflare/kumo/components/text";
import {
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowCounterClockwiseIcon,
  CloudIcon,
  DatabaseIcon,
  DeviceMobileIcon,
  KeyIcon,
  LaptopIcon,
  PauseIcon,
  PlayIcon,
  ShieldCheckIcon,
  TicketIcon,
} from "@phosphor-icons/react";
import { scenarios, worldAt, type Actor, type Message, type World } from "./story";

const ACTORS: { id: Actor; name: string; role: string; icon: ReactNode }[] = [
  { id: "you", name: "You", role: "browser or phone", icon: <DeviceMobileIcon size={22} /> },
  { id: "access", name: "Cloudflare Access", role: "checks people", icon: <ShieldCheckIcon size={22} /> },
  { id: "relay", name: "Axo relay", role: "axo.leostera.dev", icon: <CloudIcon size={22} /> },
  { id: "mac", name: "Your Mac", role: "axod", icon: <LaptopIcon size={22} /> },
];
const CENTER: Record<Actor, number> = { you: 12.5, access: 37.5, relay: 62.5, mac: 87.5 };

export type Depth = "simple" | "detailed";

/** `#tour/link/3` opens step 3 of "Link this Mac". */
function fromHash(): { scenario: string; step: number } {
  const [, id, step] = location.hash.slice(1).split("/");
  const scenario = scenarios.find((s) => s.id === id) ?? scenarios[0]!;
  const index = Math.min(Math.max(Number(step) - 1 || 0, 0), scenario.steps.length - 1);
  return { scenario: scenario.id, step: index };
}

export function GuidedTour({ depth }: { depth: Depth }) {
  const [scenarioId, setScenarioId] = useState(() => fromHash().scenario);
  const [index, setIndex] = useState(() => fromHash().step);
  const [playing, setPlaying] = useState(false);

  const scenario = scenarios.find((s) => s.id === scenarioId)!;
  const step = scenario.steps[index]!;
  const world = useMemo(() => worldAt(scenario, index), [scenario, index]);
  const last = index === scenario.steps.length - 1;

  useEffect(() => {
    history.replaceState(null, "", `#tour/${scenarioId}/${index + 1}`);
  }, [scenarioId, index]);

  useEffect(() => {
    if (!playing) return;
    if (last) {
      setPlaying(false);
      return;
    }
    const timer = setTimeout(() => setIndex((i) => i + 1), 3200);
    return () => clearTimeout(timer);
  }, [playing, index, last]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "ArrowRight") setIndex((i) => Math.min(i + 1, scenario.steps.length - 1));
      if (event.key === "ArrowLeft") setIndex((i) => Math.max(i - 1, 0));
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [scenario]);

  const choose = (id: string) => {
    setScenarioId(id);
    setIndex(0);
    setPlaying(false);
  };

  return (
    <div className="flex flex-col gap-6">
      <Text variant="secondary">
        Five scripted stories, one step at a time. For the whole system, with as many Macs, phones and
        people as you like, use the Simulator.
      </Text>

      <Tabs
        variant="underline"
        value={scenarioId}
        onValueChange={choose}
        tabs={scenarios.map((s) => ({ value: s.id, label: s.name }))}
      />

      <LayerCard>
        <LayerCard.Secondary className="flex flex-wrap items-center justify-between gap-2">
          <span>{scenario.summary}</span>
          <Text variant="secondary" size="sm">
            Step {index + 1} of {scenario.steps.length}
          </Text>
        </LayerCard.Secondary>
        <LayerCard.Primary className="flex flex-col gap-6">
          <Diagram world={world} focus={step.focus} message={step.message} stepKey={`${scenarioId}-${index}`} />
          <div className="flex flex-col gap-3">
            <Text variant="heading" as="h2">
              {index + 1}. {step.title}
            </Text>
            <Text size="lg">{step.plain}</Text>
            {depth === "detailed" && (
              <div className="rounded-lg bg-kumo-recessed p-3">
                <Text variant="secondary">
                  <Markdownish text={step.detail} />
                </Text>
              </div>
            )}
          </div>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex gap-1.5">
              {scenario.steps.map((s, i) => (
                <button
                  key={s.title}
                  aria-label={`Go to step ${i + 1}: ${s.title}`}
                  onClick={() => setIndex(i)}
                  className={`h-2.5 rounded-full transition-all ${
                    i === index ? "w-8 bg-kumo-brand" : i < index ? "w-2.5 bg-kumo-brand/50" : "w-2.5 bg-kumo-line"
                  }`}
                />
              ))}
            </div>
            <div className="flex gap-2">
              <Button
                variant="ghost"
                icon={<ArrowCounterClockwiseIcon size={16} />}
                onClick={() => {
                  setIndex(0);
                  setPlaying(false);
                }}
              >
                Restart
              </Button>
              <Button icon={<ArrowLeftIcon size={16} />} disabled={index === 0} onClick={() => setIndex(index - 1)}>
                Back
              </Button>
              <Button
                icon={playing ? <PauseIcon size={16} /> : <PlayIcon size={16} />}
                disabled={last && !playing}
                onClick={() => setPlaying((p) => !p)}
              >
                {playing ? "Pause" : "Play"}
              </Button>
              <Button
                variant="primary"
                icon={<ArrowRightIcon size={16} />}
                disabled={last}
                onClick={() => setIndex(index + 1)}
              >
                Next
              </Button>
            </div>
          </div>
        </LayerCard.Primary>
      </LayerCard>

      <section className="grid gap-4 md:grid-cols-3">
        <SettingsPreview world={world} />
        <MacMemory world={world} depth={depth} />
        <RelayMemory world={world} depth={depth} />
      </section>

      <TrustTable />
      <Questions />

      <footer className="pb-6">
        <Text variant="secondary" size="sm">
          Written against Axo V0. Settings will also show the linked account and relay, and gain an
          Unlink button. Phones are not paired: they sign in with Cloudflare Access.
        </Text>
      </footer>
    </div>
  );
}

/** Renders `code` spans; nothing else. */
function Markdownish({ text }: { text: string }) {
  return (
    <>
      {text.split(/(`[^`]+`)/).map((part, i) =>
        part.startsWith("`") ? (
          <code key={i} className="rounded bg-kumo-base px-1 py-0.5 font-mono text-[0.85em] text-kumo-default">
            {part.slice(1, -1)}
          </code>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
}

function Diagram({ world, focus, message, stepKey }: { world: World; focus: Actor[]; message?: Message; stepKey: string }) {
  return (
    <div className="relative pt-14">
      <div className="absolute inset-x-[12.5%] top-[calc(3.5rem+52px)] h-0.5 bg-kumo-line" aria-hidden />
      <div className="grid grid-cols-4 gap-4">
        {ACTORS.map((actor) => (
          <div key={actor.id} className="relative z-10 rounded-xl bg-kumo-base">
          <motion.div
            animate={{ opacity: focus.includes(actor.id) ? 1 : 0.45, scale: focus.includes(actor.id) ? 1 : 0.97 }}
            className={`flex h-full flex-col items-center gap-2 rounded-xl bg-kumo-elevated p-4 text-center ring ${
              focus.includes(actor.id) ? "ring-kumo-brand" : "ring-kumo-line"
            }`}
          >
            <div className="flex h-10 w-10 items-center justify-center rounded-full bg-kumo-recessed">{actor.icon}</div>
            <div>
              <Text bold>{actor.name}</Text>
              <Text variant="secondary" size="xs">
                {actor.role}
              </Text>
            </div>
            <ActorBadge actor={actor.id} world={world} />
          </motion.div>
          </div>
        ))}
      </div>
      {message && <Packet key={stepKey} message={message} />}
    </div>
  );
}

function ActorBadge({ actor, world }: { actor: Actor; world: World }) {
  switch (actor) {
    case "you":
      return world.phoneAttached ? (
        <Badge variant="purple">viewing the Mac</Badge>
      ) : world.signedIn ? (
        <Badge variant="success">signed in</Badge>
      ) : (
        <Badge variant="neutral">signed out</Badge>
      );
    case "access":
      return <Badge variant="outline">people only</Badge>;
    case "relay":
      return world.code?.state === "valid" ? (
        <Badge variant="warning" icon={<TicketIcon size={12} />}>
          code waiting
        </Badge>
      ) : world.relayHost ? (
        <Badge variant={world.relayHost.state === "online" ? "success" : world.relayHost.state === "revoked" ? "error" : "neutral"}>
          Mac {world.relayHost.state}
        </Badge>
      ) : (
        <Badge variant="neutral">doesn't know your Mac</Badge>
      );
    case "mac":
      return <ConnectionBadge world={world} />;
  }
}

function ConnectionBadge({ world }: { world: World }) {
  const variant = {
    "not linked": "neutral",
    connecting: "warning",
    connected: "success",
    disconnected: "error",
  } as const;
  return (
    <Badge appearance="dot" variant={variant[world.connection]}>
      {world.connection}
    </Badge>
  );
}

const TONE = {
  request: "bg-kumo-brand text-white",
  reply: "bg-green-600 text-white",
  refused: "bg-red-600 text-white",
  stream: "bg-purple-600 text-white",
} as const;

function Packet({ message }: { message: Message }) {
  const tone = message.tone ?? "request";
  const from = CENTER[message.from];
  const to = CENTER[message.to];
  const local = (message.from === "you" && message.to === "mac" && tone !== "stream") ||
    (message.from === "mac" && message.to === "you" && tone !== "stream" && tone !== "reply");
  const throughRelay = tone === "stream" && [message.from, message.to].sort().join() === "mac,you";

  const left = throughRelay
    ? [`${from}%`, `${CENTER.relay}%`, `${to}%`]
    : tone === "refused"
      ? [`${from}%`, `${(from + to) / 2}%`, `${(from + to) / 2}%`]
      : [`${from}%`, `${to}%`];
  // Packets travel in the band above the boxes; a local hop arcs up instead of crossing the internet.
  const top = local ? [14, -14, 14] : [14, 14, 14].slice(0, left.length);

  return (
    <motion.div
      className="pointer-events-none absolute z-20 -translate-x-1/2"
      initial={{ left: left[0], top: top[0], opacity: 0 }}
      animate={{ left, top, opacity: tone === "refused" ? [0, 1, 0.9, 0] : [0, 1, 1, 1] }}
      transition={{ duration: throughRelay || local ? 2.2 : 1.6, ease: "easeInOut", repeat: Infinity, repeatDelay: 0.8 }}
    >
      <div className={`whitespace-nowrap rounded-full px-3 py-1 text-xs font-medium shadow-lg ${TONE[tone]}`}>
        {tone === "refused" ? "✕ " : ""}
        {message.label}
        {local ? " · on this Mac" : ""}
      </div>
    </motion.div>
  );
}

function SettingsPreview({ world }: { world: World }) {
  return (
    <LayerCard>
      <LayerCard.Secondary>Settings → Remote Access</LayerCard.Secondary>
      <LayerCard.Primary className="flex flex-col gap-3">
        <Row label="Status">
          <ConnectionBadge world={world} />
        </Row>
        <Row label="This Mac">
          <Text size="sm">leos-macbook · macOS</Text>
        </Row>
        <Row label="Account">
          <Text variant="mono-secondary">{world.link.account ?? "—"}</Text>
        </Row>
        {world.lastError && (
          <Banner variant="error" size="sm" title="Last error" description={world.lastError} />
        )}
        {world.connection === "not linked" && (
          <Text variant="secondary" size="sm">
            Paste a pairing code from axo.leostera.dev to link this Mac.
          </Text>
        )}
      </LayerCard.Primary>
    </LayerCard>
  );
}

function MacMemory({ world, depth }: { world: World; depth: Depth }) {
  const { account, credential, pending } = world.link;
  return (
    <LayerCard>
      <LayerCard.Secondary className="flex items-center gap-2">
        <LaptopIcon size={16} /> What your Mac remembers
      </LayerCard.Secondary>
      <LayerCard.Primary className="flex flex-col gap-3">
        <Memory icon={<DatabaseIcon size={14} />} title={depth === "detailed" ? "axo.db · host_link" : "Its notebook (database)"}>
          <Row label="account">
            <Cell value={account} />
          </Row>
          <Row label="uses secret">
            <Cell value={credential} />
          </Row>
          <Row label="linking in progress">
            <Cell value={pending} highlight />
          </Row>
        </Memory>
        <Memory icon={<KeyIcon size={14} />} title={depth === "detailed" ? "Login Keychain" : "Its safe (Keychain)"}>
          {world.keychain.length === 0 ? (
            <Text variant="secondary" size="sm">
              empty
            </Text>
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {world.keychain.map((id) => (
                <motion.span key={id} initial={{ scale: 0.6, opacity: 0 }} animate={{ scale: 1, opacity: 1 }}>
                  <Badge variant="teal" icon={<KeyIcon size={12} />}>
                    {id}: ••••••
                  </Badge>
                </motion.span>
              ))}
            </div>
          )}
        </Memory>
        <Text variant="secondary" size="xs">
          The notebook only holds IDs. The secret itself never leaves the safe, except to prove who
          the Mac is to the relay.
        </Text>
      </LayerCard.Primary>
    </LayerCard>
  );
}

function RelayMemory({ world, depth }: { world: World; depth: Depth }) {
  return (
    <LayerCard>
      <LayerCard.Secondary className="flex items-center gap-2">
        <CloudIcon size={16} /> What the relay remembers
      </LayerCard.Secondary>
      <LayerCard.Primary className="flex flex-col gap-3">
        <Memory icon={<TicketIcon size={14} />} title="Pairing code">
          {world.code ? (
            <Row label={world.code.value}>
              <Badge variant={world.code.state === "valid" ? "warning" : "neutral"}>
                {world.code.state === "valid" ? "valid for 10 min" : "used up"}
              </Badge>
            </Row>
          ) : (
            <Text variant="secondary" size="sm">
              none
            </Text>
          )}
        </Memory>
        <Memory icon={<LaptopIcon size={14} />} title={depth === "detailed" ? "Account's hosts" : "Your Macs"}>
          {world.relayHost ? (
            <>
              <Row label="leos-macbook">
                <Badge variant={world.relayHost.state === "online" ? "success" : world.relayHost.state === "revoked" ? "error" : "neutral"}>
                  {world.relayHost.state}
                </Badge>
              </Row>
              <Row label="checks secret">
                <Text variant="mono-secondary">{world.relayHost.credential} (fingerprint)</Text>
              </Row>
            </>
          ) : (
            <Text variant="secondary" size="sm">
              none
            </Text>
          )}
        </Memory>
        <Text variant="secondary" size="xs">
          The relay keeps a fingerprint of the secret ({depth === "detailed" ? "an HMAC verifier" : "enough to check it, not to copy it"}), and of the code.
        </Text>
      </LayerCard.Primary>
    </LayerCard>
  );
}

function Memory({ icon, title, children }: { icon: ReactNode; title: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2 rounded-lg bg-kumo-recessed p-3">
      <div className="flex items-center gap-1.5">
        {icon}
        <Text size="sm" bold>
          {title}
        </Text>
      </div>
      {children}
    </div>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <Text variant="secondary" size="sm">
        {label}
      </Text>
      {children}
    </div>
  );
}

function Cell({ value, highlight }: { value: string | null; highlight?: boolean }) {
  return (
    <motion.span key={value ?? "none"} initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }}>
      {value ? (
        <Badge variant={highlight ? "warning" : "blue"}>{value}</Badge>
      ) : (
        <Text variant="mono-secondary">—</Text>
      )}
    </motion.span>
  );
}

function TrustTable() {
  const rows = [
    ["You, in a browser", "Cloudflare Access sign-in", "Sign out, or remove access in Cloudflare"],
    ["You, on a phone", "Cloudflare Access sign-in (never paired)", "Revoke the device's Access session"],
    ["Your Mac", "A secret made at pairing, kept in the Keychain", "Revoke it on the website"],
    ["The local app", "Being your user on this Mac (private socket)", "—"],
  ];
  return (
    <LayerCard>
      <LayerCard.Secondary>Who proves what</LayerCard.Secondary>
      <LayerCard.Primary className="p-0">
        <Table>
          <Table.Header>
            <Table.Row>
              <Table.Head>Who</Table.Head>
              <Table.Head>How it proves who it is</Table.Head>
              <Table.Head>How you cut it off</Table.Head>
            </Table.Row>
          </Table.Header>
          <Table.Body>
            {rows.map(([who, how, cut]) => (
              <Table.Row key={who}>
                <Table.Cell>{who}</Table.Cell>
                <Table.Cell>{how}</Table.Cell>
                <Table.Cell>{cut}</Table.Cell>
              </Table.Row>
            ))}
          </Table.Body>
        </Table>
      </LayerCard.Primary>
    </LayerCard>
  );
}

const QUESTIONS: [string, string][] = [
  [
    "Why only pair the Mac, not my phone?",
    "Pairing gives a machine its own long-lived secret, so it can connect with nobody around. Your phone always has you holding it, so it can just sign in like a browser. One less secret to lose.",
  ],
  [
    "Can Axo read my terminal?",
    "The relay passes your terminal's messages along, and it can see them: there's no end-to-end encryption. The trust boundary is your own Cloudflare deployment. Today the relay doesn't store terminal output.",
  ],
  [
    "What if someone steals the pairing code?",
    "It works once, for 10 minutes, and redemption is rate limited. If someone uses it before you, their machine shows up in your host list and you revoke it.",
  ],
  [
    "What if someone copies axo.db?",
    "They get IDs, not the secret. The secret is in your Keychain.",
  ],
  [
    "Where is the relay address set?",
    "Nowhere, normally: it's always axo.leostera.dev. Developers and tests can point axod elsewhere with --relay-url or AXO_RELAY_URL. Only a relay on this machine may use plain HTTP.",
  ],
];

function Questions() {
  const [open, setOpen] = useState<string | null>(null);
  return (
    <section className="flex flex-col gap-2">
      <Text variant="heading" as="h2">
        Questions
      </Text>
      {QUESTIONS.map(([question, answer]) => (
        <Collapsible.Root key={question} open={open === question} onOpenChange={(o: boolean) => setOpen(o ? question : null)}>
          <Collapsible.DefaultTrigger>{question}</Collapsible.DefaultTrigger>
          <Collapsible.DefaultPanel>
            <Text>{answer}</Text>
          </Collapsible.DefaultPanel>
        </Collapsible.Root>
      ))}
    </section>
  );
}

