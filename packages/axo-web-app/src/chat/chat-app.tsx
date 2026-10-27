import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { RemoteAxoApi, type Host } from "@axo/app";
import { hostPairingCreateResultSchema } from "@axo/protocol/v1";
import { AxoMascot } from "../axo-mascot.tsx";
import { Conversation } from "./conversation.tsx";
import { Icon } from "./icons.tsx";
import { relativeTime } from "./message-views.tsx";
import { chatTitle, ChatWorkbench, isChat, type ChatBackend } from "./workbench.ts";

const DEFAULT_API_URL = "https://axo.leostera.dev";
const apiBaseUrl = import.meta.env.VITE_AXO_API_BASE_URL || DEFAULT_API_URL;
const HOSTS_REFRESH_MS = 30_000;
/** While a pairing code is up, how often to look for the Mac that redeems it. */
const PAIRING_POLL_MS = 3_000;
/** From here up the layers sit side by side; below, they stack as on the phone. */
const WIDE_QUERY = "(min-width: 900px)";

export type AccountProfile = { email: string | null; name: string | null };

/** The phone's layers, left to right. The conversation is home. */
type Layer = "account" | "chats" | "conversation" | "info";
const layerOrder: Layer[] = ["account", "chats", "conversation", "info"];

type Appearance = "system" | "light" | "dark";
const APPEARANCE_KEY = "axo.appearance";

function useWide(): boolean {
  return useSyncExternalStore(
    listener => {
      const query = window.matchMedia(WIDE_QUERY);
      query.addEventListener("change", listener);
      return () => query.removeEventListener("change", listener);
    },
    () => window.matchMedia(WIDE_QUERY).matches,
  );
}

function useAppearance(): [Appearance, (value: Appearance) => void] {
  const [appearance, setAppearance] = useState<Appearance>(() => {
    const stored = localStorage.getItem(APPEARANCE_KEY);
    return stored === "light" || stored === "dark" ? stored : "system";
  });
  useEffect(() => {
    if (appearance === "system") {
      delete document.documentElement.dataset.appearance;
      localStorage.removeItem(APPEARANCE_KEY);
    } else {
      document.documentElement.dataset.appearance = appearance;
      localStorage.setItem(APPEARANCE_KEY, appearance);
    }
  }, [appearance]);
  return [appearance, setAppearance];
}

/** The signed-in app: chats with Axo on your Macs, as on the phone. */
export function ChatApp({ profile, backend, onSignOut, pairingUrl }: {
  profile?: AccountProfile;
  /** Tests give their own; otherwise the account's API. */
  backend?: ChatBackend;
  onSignOut?: () => void;
  /** Where pairing codes are made; no pairing without it. */
  pairingUrl?: string;
}) {
  const workbench = useMemo(() => new ChatWorkbench(backend ?? new RemoteAxoApi(apiBaseUrl)), [backend]);
  useSyncExternalStore(workbench.subscribe, workbench.getVersion);
  const wide = useWide();
  const [layer, setLayer] = useState<Layer>("conversation");
  const [infoOpen, setInfoOpen] = useState(false);
  const [sheet, setSheet] = useState<"settings" | "pair" | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    void workbench.refreshHosts(controller.signal);
    const timer = window.setInterval(() => void workbench.refreshHosts(), HOSTS_REFRESH_MS);
    return () => {
      controller.abort();
      window.clearInterval(timer);
      workbench.dispose();
    };
  }, [workbench]);

  // ⌘K or ⌘N: a new chat, as on the phone's Chat button.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey || event.ctrlKey) || event.repeat || !["k", "n"].includes(event.key.toLowerCase())) return;
      event.preventDefault();
      workbench.newChat();
      setLayer("conversation");
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [workbench]);

  // Side by side, the chats and the conversation are both on screen: showing either is home.
  const show = (next: Layer) => setLayer(wide && next === "chats" ? "conversation" : next);
  const toggleInfo = () => {
    if (wide) setInfoOpen(!infoOpen);
    else setLayer(layer === "info" ? "conversation" : "info");
  };

  // A swipe moves the stack one layer, as on the phone; only where the layers stack.
  const swipe = useRef<{ x: number; y: number; id: number } | null>(null);
  const onPointerDown = (event: ReactPointerEvent) => {
    if (wide || event.pointerType === "mouse") return;
    swipe.current = { x: event.clientX, y: event.clientY, id: event.pointerId };
  };
  const onPointerUp = (event: ReactPointerEvent) => {
    const start = swipe.current;
    swipe.current = null;
    if (!start || start.id !== event.pointerId) return;
    const dx = event.clientX - start.x;
    const dy = event.clientY - start.y;
    if (Math.abs(dx) < 60 || Math.abs(dx) < Math.abs(dy) * 1.5) return;
    const index = layerOrder.indexOf(layer) + (dx > 0 ? -1 : 1);
    const next = layerOrder[Math.max(0, Math.min(layerOrder.length - 1, index))]!;
    setLayer(next);
  };

  const sidebar: Layer = wide ? (layer === "account" ? "account" : "chats") : layer;
  const stackClass = wide
    ? `stack wide sidebar-${sidebar}${infoOpen ? " info-open" : ""}`
    : `stack narrow at-${layer}`;

  return (
    <main className="chat-app">
      <div className={stackClass} onPointerDown={onPointerDown} onPointerUp={onPointerUp} onPointerCancel={() => { swipe.current = null; }}>
        <div className="layer layer-account" inert={wide ? sidebar !== "account" : layer !== "account"}>
          <AccountPanel
            workbench={workbench}
            profile={profile}
            onOpenMac={hostId => {
              workbench.openMac(hostId);
              show("chats");
            }}
            onShowChats={() => show("chats")}
            onPair={pairingUrl ? () => setSheet("pair") : undefined}
            onSettings={() => setSheet("settings")}
          />
        </div>
        <div className="layer layer-chats" inert={wide ? sidebar !== "chats" : layer !== "chats"}>
          <ChatsPanel
            workbench={workbench}
            onSelect={(hostId, sessionId) => {
              workbench.selectChat(hostId, sessionId);
              show("conversation");
            }}
            onNewChat={(hostId, workspaceId) => {
              workbench.newChat(hostId, workspaceId);
              show("conversation");
            }}
            onAccount={() => show("account")}
            onSettings={() => setSheet("settings")}
          />
        </div>
        <div className="layer layer-conversation" inert={!wide && layer !== "conversation"}>
          <Conversation workbench={workbench} wide={wide} onShowChats={() => show("chats")} onToggleInfo={toggleInfo} />
        </div>
        {!wide && (layer === "chats" || layer === "account") ? (
          // The strip of the next layer is a way back to it, as on the phone.
          <button className="layer-edge" onClick={() => show(layer === "account" ? "chats" : "conversation")}
            aria-label={layer === "account" ? "Chats" : "Conversation"} />
        ) : null}
        <div className="layer layer-info" inert={wide ? !infoOpen : layer !== "info"}>
          <InfoPanel workbench={workbench} onClose={toggleInfo} />
        </div>
        {!wide && layer === "info" ? (
          <button className="layer-edge info-edge" onClick={() => show("conversation")} aria-label="Conversation" />
        ) : null}
      </div>
      {sheet === "settings" ? <SettingsSheet onClose={() => setSheet(null)} onSignOut={onSignOut} /> : null}
      {sheet === "pair" && pairingUrl ? <PairMacSheet workbench={workbench} pairingUrl={pairingUrl} onClose={() => setSheet(null)} /> : null}
    </main>
  );
}

// MARK: - Chats

function StatusDot({ status }: { status: Host["sessions"][number]["status"] }) {
  switch (status) {
    case "working": return <span className="status-dot working" aria-label="Working" />;
    case "needsAttention": return <span className="status-dot attention" aria-label="Needs your attention" />;
    case "unavailable": return <span className="status-unavailable" aria-label="Stopped"><Icon name="warning" size={13} /></span>;
    default: return null;
  }
}

function ChatsPanel({ workbench, onSelect, onNewChat, onAccount, onSettings }: {
  workbench: ChatWorkbench;
  onSelect: (hostId: string, sessionId: number) => void;
  onNewChat: (hostId: string | null, workspaceId: string | null) => void;
  onAccount: () => void;
  onSettings: () => void;
}) {
  const sections = workbench.sections();
  const selection = workbench.selection;
  return (
    <nav className="panel chats-panel" aria-label="Chats">
      <header className="layer-bar top panel-header">
        <AxoMascot className="header-mascot" loading={workbench.hostsPhase === "loading"} />
        <span className="spacer" />
        <button className="circle-button" onClick={onAccount} aria-label="Account and Macs"><Icon name="person" /></button>
      </header>
      <div className="panel-scroll">
        {workbench.hostsPhase === "failed" && workbench.failure ? <p className="panel-warning">{workbench.failure}</p> : null}
        {sections.map((section, index) => (
          <section key={section.id} className={index === 0 ? "chat-section first" : "chat-section"}>
            <h2 className="section-title">
              <span>{section.title}</span>
              {section.workspaceId ? (
                <button className="plain-icon-button" onClick={() => onNewChat(section.host.hostId, section.workspaceId)} aria-label={`New chat in ${section.title}`}>
                  <Icon name="compose" size={15} />
                </button>
              ) : null}
            </h2>
            {section.chats.map(({ host, session }) => {
              const selected = host.hostId === workbench.openHostId && selection?.kind === "chat" && selection.sessionId === session.sessionId;
              return (
                <button key={`${host.hostId}/${session.sessionId}`} className={selected ? "chat-row selected" : "chat-row"}
                  aria-current={selected ? "page" : undefined} onClick={() => onSelect(host.hostId, session.sessionId)}>
                  <span className="chat-row-name">{chatTitle(session)}</span>
                  <StatusDot status={session.status} />
                </button>
              );
            })}
            {section.chats.length === 0 ? <p className="no-chats">No chats yet</p> : null}
          </section>
        ))}
        {sections.length === 0 ? (
          workbench.hostsPhase === "loaded" && workbench.hosts.length === 0 ? (
            <div className="panel-empty">
              <Icon name="laptop" size={28} />
              <strong>No Macs yet</strong>
              <p>On a Mac, open Axo → Settings → Remote Access and link it with a pairing code.</p>
            </div>
          ) : <p className="panel-note">{workbench.hostsPhase === "loading" ? "Loading chats…" : "Your chats will appear here."}</p>
        ) : null}
      </div>
      <footer className="layer-bar bottom panel-footer">
        <button className="pill-button primary" onClick={() => onNewChat(null, null)}><Icon name="compose" size={18} /> Chat</button>
        <span className="spacer" />
        <button className="circle-button" onClick={onSettings} aria-label="Settings"><Icon name="gear" /></button>
      </footer>
    </nav>
  );
}

// MARK: - Account

function hostSummary(host: Host): string {
  const chats = host.sessions.filter(isChat).length;
  const count = chats === 1 ? "1 chat" : `${chats} chats`;
  if (host.status === "online") return count;
  const seen = Date.parse(host.lastSeenAt);
  return Number.isNaN(seen) ? `${count} · offline` : `${count} · last seen ${relativeTime(seen)}`;
}

function AccountPanel({ workbench, profile, onOpenMac, onShowChats, onPair, onSettings }: {
  workbench: ChatWorkbench;
  profile?: AccountProfile;
  onOpenMac: (hostId: string) => void;
  onShowChats: () => void;
  onPair?: () => void;
  onSettings: () => void;
}) {
  const name = profile?.name || profile?.email?.split("@")[0] || "Axo account";
  return (
    <nav className="panel account-panel" aria-label="Account">
      <header className="layer-bar top panel-header">
        <h1 className="panel-title">Account</h1>
        <span className="spacer" />
        <button className="circle-button wide-only" onClick={onShowChats} aria-label="Back to chats"><Icon name="close" size={16} /></button>
      </header>
      <div className="panel-scroll">
        <div className="profile">
          <span className="avatar" aria-hidden="true">{name.slice(0, 1).toUpperCase()}</span>
          <span className="profile-copy">
            <strong>{name}</strong>
            {profile?.email ? <span>{profile.email}</span> : null}
            <small>Signed in with Cloudflare</small>
          </span>
        </div>
        <h2 className="section-title"><span>Macs</span></h2>
        {workbench.hosts.map(host => (
          <button key={host.hostId} className={host.hostId === workbench.openHostId ? "mac-row selected" : "mac-row"}
            aria-current={host.hostId === workbench.openHostId ? "true" : undefined} onClick={() => onOpenMac(host.hostId)}>
            <Icon name="laptop" size={22} />
            <span className="mac-copy">
              <strong>{host.label}</strong>
              <small>{hostSummary(host)}</small>
            </span>
            <span className={`mac-dot ${host.status}`} aria-label={host.status === "online" ? "Online" : "Offline"} />
          </button>
        ))}
        {workbench.hostsPhase === "loaded" && workbench.hosts.length === 0 ? <p className="panel-note">No Macs yet. Pair one to start.</p> : null}
      </div>
      <footer className="layer-bar bottom panel-footer">
        {onPair ? <button className="pill-button primary" onClick={onPair}><Icon name="pair" size={18} /> Pair a Mac</button> : null}
        <span className="spacer" />
        <button className="circle-button" onClick={onSettings} aria-label="Settings"><Icon name="gear" /></button>
      </footer>
    </nav>
  );
}

// MARK: - Info

const statusNames = { starting: "Starting", ready: "Ready", working: "Working", needsAttention: "Needs you", unavailable: "Unavailable" } as const;

function InfoPanel({ workbench, onClose }: { workbench: ChatWorkbench; onClose: () => void }) {
  const host = workbench.openHost;
  const session = workbench.selectedSession;
  const chat = session ? workbench.chat(session.sessionId) : null;
  const subtitle = [session?.workspaceName, host?.label].filter(Boolean).join(" · ") || "No Mac";
  const messages = chat?.transcript
    ? `${chat.transcript.messages.length}${chat.history.kind === "loadingOlder" || (chat.history.kind === "loaded" && chat.history.hasOlder) ? "+" : ""}`
    : "Not loaded";
  const updated = session ? Date.parse(session.updatedAt) : Number.NaN;
  return (
    <aside className="panel info-panel" aria-label="Chat info">
      <header className="layer-bar top panel-header">
        <span className="spacer" />
        <button className="circle-button" onClick={onClose} aria-label="Close chat info"><Icon name="close" size={16} /></button>
      </header>
      <div className="panel-scroll">
        <AxoMascot className="info-mascot" loading={session?.status === "working"} />
        <h2 className="info-title">{[session?.emoji, chatTitle(session)].filter(Boolean).join(" ")}</h2>
        <p className="info-subtitle">{subtitle}</p>
        {session && host ? (
          <dl className="facts">
            <div><dt>Status</dt><dd>{session.status ? statusNames[session.status] : "Unknown"}</dd></div>
            <div><dt>Mac</dt><dd>{host.label}, {host.status === "online" ? "online" : "offline"}</dd></div>
            {session.workspaceName ? <div><dt>Workspace</dt><dd>{session.workspaceName}</dd></div> : null}
            <div><dt>Messages</dt><dd>{messages}</dd></div>
            <div><dt>Terminals</dt><dd>{session.shells.length}</dd></div>
            {Number.isNaN(updated) ? null : <div><dt>Last active</dt><dd>{relativeTime(updated)}</dd></div>}
            <div><dt>Chat</dt><dd className="mono">{session.sessionUuid ?? session.sessionId}</dd></div>
          </dl>
        ) : (
          <p className="panel-note centered">Nothing here yet. Send a message and this chat starts on your Mac.</p>
        )}
      </div>
    </aside>
  );
}

// MARK: - Sheets

function Sheet({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);
  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <section className="sheet" role="dialog" aria-modal="true" aria-label={title} onClick={event => event.stopPropagation()}>
        <header className="sheet-header">
          <span className="circle-placeholder" />
          <h2>{title}</h2>
          <button className="circle-button" onClick={onClose} aria-label={`Close ${title}`}><Icon name="close" size={16} /></button>
        </header>
        {children}
      </section>
    </div>
  );
}

function SettingsSheet({ onClose, onSignOut }: { onClose: () => void; onSignOut?: () => void }) {
  const [appearance, setAppearance] = useAppearance();
  return (
    <Sheet title="Settings" onClose={onClose}>
      <h3 className="sheet-section">Theme</h3>
      <label className="setting-row">
        <span>Appearance</span>
        <select value={appearance} onChange={event => setAppearance(event.target.value as Appearance)}>
          <option value="system">System</option>
          <option value="light">Light</option>
          <option value="dark">Dark</option>
        </select>
      </label>
      {onSignOut ? (
        <>
          <button className="sign-out" onClick={onSignOut}>Sign out</button>
          <p className="sheet-note">Signing out ends this browser's session. Your Macs and conversations stay on your account.</p>
        </>
      ) : null}
      <p className="sheet-build">axo web · {__AXO_WEB_BUILD__}</p>
    </Sheet>
  );
}

type Pairing =
  | { kind: "creating" }
  | { kind: "waiting"; code: string; expiresAt: number }
  | { kind: "linked"; label: string }
  | { kind: "expired" }
  | { kind: "failed"; message: string };

/** A one-time code for a Mac to redeem; says so when a new Mac shows up on the account. */
function PairMacSheet({ workbench, pairingUrl, onClose }: { workbench: ChatWorkbench; pairingUrl: string; onClose: () => void }) {
  const [pairing, setPairing] = useState<Pairing>({ kind: "creating" });
  const [now, setNow] = useState(Date.now());
  const [copied, setCopied] = useState(false);
  const known = useRef(new Set(workbench.hosts.map(host => host.hostId)));

  const create = async () => {
    setPairing({ kind: "creating" });
    known.current = new Set(workbench.hosts.map(host => host.hostId));
    try {
      const response = await fetch(pairingUrl, { method: "POST", credentials: "include", cache: "no-store" });
      const result = hostPairingCreateResultSchema.safeParse(await response.json());
      if (!response.ok || !result.success) throw new Error(response.status === 429 ? "Too many codes. Wait a minute and try again." : `Could not make a code (${response.status}).`);
      setPairing({ kind: "waiting", code: result.data.code, expiresAt: Date.parse(result.data.expiresAt) });
    } catch (error) {
      setPairing({ kind: "failed", message: error instanceof Error ? error.message : "Could not make a code." });
    }
  };

  // Once per sheet: a code is a rate-limited request (React's strict mode runs effects twice).
  const started = useRef(false);
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    void create();
  }, []);

  useEffect(() => {
    if (pairing.kind !== "waiting") return;
    const tick = window.setInterval(() => setNow(Date.now()), 1_000);
    const poll = window.setInterval(() => void workbench.refreshHosts(), PAIRING_POLL_MS);
    return () => {
      window.clearInterval(tick);
      window.clearInterval(poll);
    };
  }, [pairing.kind, workbench]);

  useEffect(() => {
    if (pairing.kind !== "waiting") return;
    const fresh = workbench.hosts.find(host => !known.current.has(host.hostId));
    if (fresh) setPairing({ kind: "linked", label: fresh.label });
    else if (now >= pairing.expiresAt) setPairing({ kind: "expired" });
  }, [workbench.version, now, pairing]);

  const remaining = pairing.kind === "waiting" ? Math.max(0, Math.round((pairing.expiresAt - now) / 1000)) : 0;
  const copy = async (code: string) => {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  return (
    <Sheet title="Pair a Mac" onClose={onClose}>
      <div className="pairing">
        <AxoMascot className="pairing-mascot" loading={pairing.kind === "creating" || pairing.kind === "waiting"} />
        {pairing.kind === "creating" ? <p className="pairing-note">Making a code…</p> : null}
        {pairing.kind === "waiting" ? (
          <>
            <strong className="pairing-code" aria-label="Pairing code">{pairing.code}</strong>
            <p className="pairing-countdown">Expires in {Math.floor(remaining / 60)}:{String(remaining % 60).padStart(2, "0")}</p>
            <div className="pairing-actions">
              <button className="pill-button" onClick={() => void copy(pairing.code)}><Icon name={copied ? "check" : "copy"} size={16} /> {copied ? "Copied" : "Copy"}</button>
              <a className="pill-button primary" href={`axo://pair/${pairing.code}`}>Open Axo on this Mac</a>
            </div>
            <p className="pairing-note">On your Mac, open Axo → Settings → Remote Access, and enter this code under Link this Mac.</p>
          </>
        ) : null}
        {pairing.kind === "linked" ? (
          <>
            <strong className="pairing-done">{pairing.label} is linked</strong>
            <button className="pill-button primary" onClick={onClose}>Done</button>
          </>
        ) : null}
        {pairing.kind === "expired" || pairing.kind === "failed" ? (
          <>
            <p className="pairing-note">{pairing.kind === "expired" ? "That code expired." : pairing.message}</p>
            <button className="pill-button primary" onClick={() => void create()}>New code</button>
          </>
        ) : null}
      </div>
    </Sheet>
  );
}
