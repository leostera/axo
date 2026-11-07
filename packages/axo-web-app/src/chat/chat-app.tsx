import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { RemoteAxoApi } from "@axo/app";
import { hostPairingCreateResultSchema } from "@axo/protocol/v1";
import { AxoMascot } from "../axo-mascot.tsx";
import { Conversation } from "./conversation.tsx";
import { AppsSettings, signInNotice, signInPage } from "./apps.tsx";
import { ChatList, ChatListSettings } from "./chat-list.tsx";
import { Icon } from "./icons.tsx";
import { Alert } from "./alert.tsx";
import { runtimeLabel } from "./pi-controls.ts";
import { relativeTime } from "./message-views.tsx";
import { parseRoute, parseSettingsRoute, routePath, settingsPath, type ChatRoute, type SettingsRoute } from "./route.ts";
import {
  chatTitle, ChatWorkbench, isChat, lastActivity, recentChatList,
  type ChatBackend, type Host,
} from "./workbench.ts";
import { assetUploader } from "./assets.ts";

const DEFAULT_API_URL = "https://axo.leostera.dev";
const apiBaseUrl = import.meta.env.VITE_AXO_API_BASE_URL || DEFAULT_API_URL;
/** While a pairing code is up, how often to look for the Mac that redeems it. */
const PAIRING_POLL_MS = 3_000;
/** From here up the layers sit side by side; below, they stack as on the phone. */
const WIDE_QUERY = "(min-width: 900px)";

export type AccountProfile = { email: string | null; name: string | null };

/** The phone's layers, left to right. The conversation is home. */
type Layer = "account" | "chats" | "conversation" | "info";

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

/**
 * Keeps the open chat in the URL: a reload or a link opens it again once the Macs are listed, and
 * Back and Forward move between the chats opened.
 */
/** While a settings page is open, the URL is its own: the chats leave it alone. */
function useChatRoute(workbench: ChatWorkbench, basePath: string, settingsOpen: boolean, onRoute: () => void): void {
  const initial = useRef<ChatRoute | null>(parseRoute(basePath, window.location.pathname));

  const follow = (route: ChatRoute) => {
    const host = route.kind === "chat" ? workbench.hosts.find(candidate => candidate.hostId === route.hostId) : undefined;
    if (route.kind === "chat" && host) workbench.selectChat(host.hostId, route.sessionId);
    else workbench.newChat();
  };

  // What is on screen, in the URL. The first listing of the Macs opens the chat the URL names, if
  // it is still there; until then the URL waits to be read.
  const path = routePath(basePath, workbench.openHostId, workbench.selection);
  useEffect(() => {
    if (workbench.hostsPhase !== "loaded" || settingsOpen) return;
    const route = initial.current;
    initial.current = null;
    if (route?.kind === "chat" && workbench.hosts.some(host =>
      host.hostId === route.hostId && host.sessions.some(session => session.sessionId === route.sessionId))) {
      follow(route);
      return;
    }
    if (window.location.pathname === path) return;
    if (route) window.history.replaceState(null, "", path);
    else window.history.pushState(null, "", path);
  }, [path, workbench.hostsPhase, settingsOpen]);

  useEffect(() => {
    const onPopState = () => {
      if (parseSettingsRoute(basePath, window.location.pathname)) return;
      follow(parseRoute(basePath, window.location.pathname));
      onRoute();
    };
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, [workbench, basePath]);
}

/** The signed-in app: chats with Axo on your Macs, as on the phone. */
export function ChatApp({ profile, backend, onSignOut, pairingUrl, appsUrl, basePath = "/app" }: {
  profile?: AccountProfile;
  /** Tests give their own; otherwise the account's API. */
  backend?: ChatBackend;
  onSignOut?: () => void;
  /** Where pairing codes are made; no pairing without it. */
  pairingUrl?: string;
  /** The account's apps API; no Apps page without it. */
  appsUrl?: string;
  /** The app's own path: chats are at `<basePath>/<hostId>/<sessionId>`. */
  basePath?: string;
}) {
  const workbench = useMemo(() => new ChatWorkbench(backend ?? new RemoteAxoApi(apiBaseUrl), undefined, undefined, undefined, undefined, assetUploader(apiBaseUrl)), [backend]);
  useSyncExternalStore(workbench.subscribe, workbench.getVersion);
  const wide = useWide();
  const [layer, setLayer] = useState<Layer>("conversation");
  const [infoOpen, setInfoOpen] = useState(false);
  const [sheet, setSheet] = useState<"settings" | "pair" | "search" | null>(null);
  // Settings › Apps is a page with its own URL. A sign-in comes back to an app's page (or, from
  // before, to `<base>/apps`) with how it went in the query, which is then dropped.
  const [settings, setSettings] = useState<SettingsRoute | null>(() => {
    if (!appsUrl) return null;
    const route = parseSettingsRoute(basePath, window.location.pathname);
    return route && window.location.pathname.replace(/\/+$/, "") === `${basePath}/apps` ? signInPage(window.location.search) : route;
  });
  const [settingsNotice] = useState(() => (settings ? signInNotice(window.location.search) : null));
  useEffect(() => {
    if (settings) window.history.replaceState(null, "", settingsPath(basePath, settings));
    else if (parseSettingsRoute(basePath, window.location.pathname)) window.history.replaceState(null, "", basePath);
  }, []);
  useEffect(() => {
    const onPopState = () => setSettings(appsUrl ? parseSettingsRoute(basePath, window.location.pathname) : null);
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, [basePath, appsUrl]);
  const openSettings = (route: SettingsRoute) => {
    window.history.pushState(null, "", settingsPath(basePath, route));
    setSettings(route);
  };
  // Closing settings goes back to the chat that was open: the chats put it in the URL.
  const closeSettings = () => setSettings(null);
  useChatRoute(workbench, basePath, settings !== null, () => setLayer("conversation"));

  useEffect(() => {
    workbench.start();
    return () => workbench.dispose();
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

  // No swipes: the panes open and close by the bars' buttons alone, so selecting a message's text
  // (a drag, or a long press on a phone) is never taken for a swipe.
  const sidebar: Layer = wide ? (layer === "account" ? "account" : "chats") : layer;
  const stackClass = wide
    ? `stack wide sidebar-${sidebar}${infoOpen ? " info-open" : ""}`
    : `stack narrow at-${layer}`;

  return (
    <main className="chat-app">
      <div className={stackClass} inert={settings !== null}>
        <div className="layer layer-account" inert={wide ? sidebar !== "account" : layer !== "account"}>
          <AccountPanel
            workbench={workbench}
            profile={profile}
            onOpenMac={hostId => {
              workbench.newChat(hostId);
              show("conversation");
            }}
            onShowChats={() => show("chats")}
            onPair={pairingUrl ? () => setSheet("pair") : undefined}
            onApps={appsUrl ? () => openSettings({ kind: "apps" }) : undefined}
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
            onNewChat={() => {
              workbench.newChat();
              show("conversation");
            }}
            onAccount={() => show("account")}
            onSearch={() => setSheet("search")}
            onSettings={() => setSheet("settings")}
          />
        </div>
        <div className="layer layer-conversation" inert={!wide && layer !== "conversation"}>
          <Conversation workbench={workbench} wide={wide} onShowChats={() => show("chats")} onToggleInfo={toggleInfo}
            onApps={appsUrl ? () => openSettings({ kind: "apps" }) : undefined} />
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
      {sheet === "search" ? (
        <SearchSheet workbench={workbench} onClose={() => setSheet(null)} onChoose={(hostId, sessionId) => {
          setSheet(null);
          workbench.selectChat(hostId, sessionId);
          show("conversation");
        }} />
      ) : null}
      {sheet === "settings" ? <SettingsSheet onClose={() => setSheet(null)} onSignOut={onSignOut}
        onApps={appsUrl ? () => { setSheet(null); openSettings({ kind: "apps" }); } : undefined} /> : null}
      {sheet === "pair" && pairingUrl ? <PairMacSheet workbench={workbench} pairingUrl={pairingUrl} onClose={() => setSheet(null)} /> : null}
      {settings && appsUrl ? (
        <AppsSettings appsUrl={appsUrl} route={settings} initialNotice={settingsNotice} onNavigate={openSettings} onClose={closeSettings} hrefOf={(route) => settingsPath(basePath, route)} />
      ) : null}
    </main>
  );
}

// MARK: - Chats

function ChatsPanel({ workbench, onSelect, onNewChat, onAccount, onSearch, onSettings }: {
  workbench: ChatWorkbench;
  onSelect: (hostId: string, sessionId: string) => void;
  onNewChat: () => void;
  onAccount: () => void;
  onSearch: () => void;
  onSettings: () => void;
}) {
  const entries = recentChatList(workbench.hosts);
  // With more than one Mac, each chat says which it is on.
  const manyHosts = workbench.hosts.length > 1;
  const selection = workbench.selection;
  const questions = workbench.questions();
  const asking = useMemo(() => new Set(questions.map(question => question.elicitation.sessionId)), [questions.map(question => question.elicitation.sessionId).join()]);
  const openChat = selection?.kind === "chat" ? entries.find(entry => entry.host.hostId === workbench.openHostId && entry.session.sessionId === selection.sessionId) ?? null : null;
  const pageVisible = usePageVisible();
  return (
    <nav className="panel chats-panel" aria-label="Chats">
      <header className="layer-bar top panel-header">
        <AxoMascot className="header-mascot" loading={workbench.hostsPhase === "loading"} />
        <span className="spacer" />
        <button className="circle-button" onClick={onAccount} aria-label="Account and Macs"><Icon name="person" /></button>
        <button className="circle-button" onClick={onSearch} aria-label="Search chats"><Icon name="search" /></button>
      </header>
      <div className="panel-scroll">
        {workbench.hostsPhase === "failed" && workbench.failure ? <p className="panel-warning">{workbench.failure}</p> : null}
        {entries.length > 0 ? (
          <ChatList showHost={manyHosts}
            entries={entries}
            asking={asking}
            openChat={openChat}
            pageVisible={pageVisible}
            isSelected={(hostId, sessionId) => hostId === workbench.openHostId && selection?.kind === "chat" && selection.sessionId === sessionId}
            onSelect={onSelect}
          />
        ) : (
          workbench.hostsPhase === "loaded" && workbench.hosts.length === 0 ? (
            <div className="panel-empty">
              <Icon name="laptop" size={28} />
              <strong>No Macs yet</strong>
              <p>On a Mac, open Axo → Settings → Remote Access and link it with a pairing code.</p>
            </div>
          ) : <p className="panel-note">{workbench.hostsPhase === "loading" ? "Loading chats…" : "Your chats will appear here."}</p>
        )}
      </div>
      <footer className="layer-bar bottom panel-footer">
        <button className="pill-button primary" onClick={onNewChat} aria-label="New chat"><Icon name="compose" size={18} /> Chat</button>
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

/**
 * A Mac of the account: tap to start a chat on it, as on the phone (an offline one cannot), or
 * name it with the pencil. The network's name for a Mac is rarely what anyone calls it.
 */
function MacRow({ host, selected, onOpen, onRename }: {
  host: Host;
  selected: boolean;
  onOpen: () => void;
  onRename: (name: string) => Promise<boolean>;
}) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(host.label);
  const [saving, setSaving] = useState(false);
  const start = () => { setName(host.label); setEditing(true); };
  const save = async () => {
    if (name.trim() === host.label) return setEditing(false);
    setSaving(true);
    const saved = await onRename(name);
    setSaving(false);
    if (saved) setEditing(false);
  };
  if (editing) {
    return (
      <form className="mac-row editing" onSubmit={event => { event.preventDefault(); void save(); }}>
        <Icon name="laptop" size={22} />
        <input className="mac-name-input" value={name} maxLength={64} autoFocus disabled={saving}
          aria-label={`Name for ${host.label}`} placeholder="Empty goes back to the Mac's own name"
          onChange={event => setName(event.target.value)}
          onKeyDown={event => { if (event.key === "Escape") { event.stopPropagation(); setEditing(false); } }} />
        <button type="submit" className="plain-icon-button" aria-label="Save the name" disabled={saving}><Icon name="check" size={16} /></button>
      </form>
    );
  }
  return (
    <div className="mac-row-wrap">
      <button className={selected ? "mac-row selected" : "mac-row"} aria-current={selected ? "true" : undefined} onClick={onOpen}
        disabled={host.status !== "online"} title={host.status === "online" ? "Start a new chat on this Mac" : undefined}>
        <Icon name="laptop" size={22} />
        <span className="mac-copy">
          <strong>{host.label}</strong>
          <small>{hostSummary(host)}</small>
        </span>
        <span className={`mac-dot ${host.status}`} aria-label={host.status === "online" ? "Online" : "Offline"} />
      </button>
      <button className="plain-icon-button mac-rename" onClick={start} aria-label={`Rename ${host.label}`} title="Rename this Mac">
        <Icon name="pencil" size={14} />
      </button>
    </div>
  );
}

function AccountPanel({ workbench, profile, onOpenMac, onShowChats, onPair, onApps, onSettings }: {
  workbench: ChatWorkbench;
  profile?: AccountProfile;
  onOpenMac: (hostId: string) => void;
  onShowChats: () => void;
  onPair?: () => void;
  onApps?: () => void;
  onSettings: () => void;
}) {
  const name = profile?.name || profile?.email || "Signed in";
  const initials = name.split(/[ @.]/).filter(Boolean).slice(0, 2).map(word => word[0]!.toUpperCase()).join("") || "?";
  return (
    <nav className="panel account-panel" aria-label="Account">
      <header className="layer-bar top panel-header">
        <h1 className="panel-title">Account</h1>
        <span className="spacer" />
        <button className="circle-button wide-only" onClick={onShowChats} aria-label="Back to chats"><Icon name="close" size={16} /></button>
      </header>
      <div className="panel-scroll">
        <div className="profile">
          <span className="avatar" aria-hidden="true">{initials}</span>
          <span className="profile-copy">
            <strong>{name}</strong>
            {profile?.email && profile.name ? <span>{profile.email}</span> : null}
            <small>Signed in with Cloudflare</small>
          </span>
        </div>
        <h2 className="section-title"><span>Macs</span></h2>
        {workbench.hosts.map(host => (
          <MacRow key={host.hostId} host={host} selected={host.hostId === workbench.openHostId}
            onOpen={() => onOpenMac(host.hostId)} onRename={name => workbench.renameHost(host.hostId, name)} />
        ))}
        {workbench.hostsPhase === "loaded" && workbench.hosts.length === 0 ? <p className="panel-note">No Macs yet. Pair one to chat with it from here.</p> : null}
        {onApps ? (
          <>
            <h2 className="section-title"><span>Apps</span></h2>
            <button className="mac-row" onClick={onApps}>
              <Icon name="plug" size={22} />
              <span className="mac-copy">
                <strong>Apps</strong>
                <small>Gmail and MCP servers</small>
              </span>
            </button>
          </>
        ) : null}
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
  const updated = session ? lastActivity(session) || Number.NaN : Number.NaN;
  const [confirmingRestart, setConfirmingRestart] = useState(false);
  const restarting = Boolean(chat?.restarting);
  const runs = runtimeLabel(session?.pi);
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
            <div><dt>Status</dt><dd>{restarting ? "Restarting…" : session.status ? statusNames[session.status] : "Unknown"}</dd></div>
            {runs ? <div><dt>Model</dt><dd>{runs}</dd></div> : null}
            <div><dt>Mac</dt><dd>{host.label}, {host.status === "online" ? "online" : "offline"}</dd></div>
            {session.workspaceName ? <div><dt>Workspace</dt><dd>{session.workspaceName}</dd></div> : null}
            <div><dt>Messages</dt><dd>{messages}</dd></div>
            {Number.isNaN(updated) ? null : <div><dt>Last active</dt><dd>{relativeTime(updated)}</dd></div>}
            <div><dt>Chat</dt><dd className="mono">{session.sessionId}</dd></div>
          </dl>
        ) : (
          <p className="panel-note centered">Nothing here yet. Send a message and this chat starts on your Mac.</p>
        )}
        {session && host ? (
          <div className="grouped info-actions">
            <button className="grouped-row nav-row" disabled={restarting || host.status !== "online"} onClick={() => setConfirmingRestart(true)}>
              {restarting ? <span className="spinner" aria-hidden="true" /> : <Icon name="restart" size={18} />}
              <span className="grouped-label">{restarting ? "Restarting Pi…" : "Restart Pi"}</span>
            </button>
          </div>
        ) : null}
      </div>
      {confirmingRestart && session ? (
        <Alert
          title="Restart Pi?"
          message={session.status === "working"
            ? "The reply it is writing stops. The conversation and the messages waiting for it are kept."
            : "Pi starts again on the same conversation. Messages waiting for it are kept."}
          confirm="Restart"
          cancel="Cancel"
          destructive={session.status === "working"}
          onConfirm={() => {
            setConfirmingRestart(false);
            void workbench.restart(session.sessionId);
          }}
          onCancel={() => setConfirmingRestart(false)}
        />
      ) : null}
    </aside>
  );
}

// MARK: - Sheets

function Sheet({ title, onClose, onBack, children }: { title: string; onClose: () => void; onBack?: () => void; children: ReactNode }) {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);
  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <section className="sheet" role="dialog" aria-modal="true" aria-label={title} onClick={event => event.stopPropagation()}>
        <header className="sheet-header">
          {onBack
            ? <button className="circle-button" onClick={onBack} aria-label="Back"><Icon name="chevronLeft" size={16} /></button>
            : <span className="circle-placeholder" />}
          <h2>{title}</h2>
          <button className="circle-button" onClick={onClose} aria-label={`Close ${title}`}><Icon name="close" size={16} /></button>
        </header>
        {children}
      </section>
    </div>
  );
}

/** Settings, in the phone's inset groups: the theme, then signing out. */
function SettingsSheet({ onClose, onSignOut, onApps }: { onClose: () => void; onSignOut?: () => void; onApps?: () => void }) {
  const [appearance, setAppearance] = useAppearance();
  return (
    <Sheet title="Settings" onClose={onClose}>
      {onApps ? (
        <div className="grouped">
          <button className="grouped-row nav-row" onClick={onApps}>
            <Icon name="plug" size={18} />
            <span className="grouped-label">Apps</span>
            <Icon name="chevronRight" size={16} />
          </button>
        </div>
      ) : null}
      <ChatListSettings />
      <h3 className="sheet-section">Theme</h3>
      <div className="grouped">
        <label className="grouped-row">
          <Icon name="moon" size={18} />
          <span className="grouped-label">Appearance</span>
          <select value={appearance} onChange={event => setAppearance(event.target.value as Appearance)}>
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </label>
      </div>
      {onSignOut ? (
        <>
          <div className="grouped spaced">
            <button className="grouped-row destructive" onClick={onSignOut}>
              <Icon name="signOut" size={18} />
              <span className="grouped-label">Sign out</span>
            </button>
          </div>
          <p className="sheet-note">Signing out ends this browser's session. Your Macs and conversations stay on your account.</p>
        </>
      ) : null}
      <p className="sheet-build">axo web · {__AXO_WEB_BUILD__}</p>
    </Sheet>
  );
}

/** Finds a chat by its name or its Workspace, across every Mac. Names only, not conversation text. */
function SearchSheet({ workbench, onClose, onChoose }: {
  workbench: ChatWorkbench;
  onClose: () => void;
  onChoose: (hostId: string, sessionId: string) => void;
}) {
  const [query, setQuery] = useState("");
  const words = query.trim().toLocaleLowerCase();
  const matches = words ? recentChatList(workbench.hosts).filter(({ session }) =>
    chatTitle(session).toLocaleLowerCase().includes(words) || (session.workspaceName ?? "").toLocaleLowerCase().includes(words)) : [];
  return (
    <Sheet title="Search" onClose={onClose}>
      <div className="grouped">
        <label className="grouped-row search-row">
          <Icon name="search" size={18} />
          <input autoFocus value={query} onChange={event => setQuery(event.target.value)} placeholder="Workspace or chat name"
            aria-label="Search chats" autoCapitalize="off" autoCorrect="off" spellCheck={false}
            onKeyDown={event => {
              const first = matches[0];
              if (event.key === "Enter" && first) onChoose(first.host.hostId, first.session.sessionId);
            }} />
          {query ? <button className="plain-icon-button" onClick={() => setQuery("")} aria-label="Clear search"><Icon name="closeCircle" size={18} /></button> : null}
        </label>
      </div>
      {!words ? (
        <div className="sheet-empty"><Icon name="search" size={28} /><strong>Search chats</strong><p>Search by chat or workspace name.</p></div>
      ) : matches.length === 0 ? (
        <div className="sheet-empty"><Icon name="search" size={28} /><strong>No results for “{query.trim()}”</strong><p>Check the spelling or try a new search.</p></div>
      ) : (
        <div className="grouped spaced">
          {matches.map(({ host, session }) => (
            <button key={`${host.hostId}/${session.sessionId}`} className="grouped-row search-result" onClick={() => onChoose(host.hostId, session.sessionId)}>
              <span className="search-result-copy">
                <span>{chatTitle(session)}</span>
                <small>{[session.workspaceName, host.label].filter(Boolean).join(" · ")}</small>
              </span>
            </button>
          ))}
        </div>
      )}
      <p className="sheet-note">Search uses chat and workspace names only, not conversation text.</p>
    </Sheet>
  );
}

type Pairing =
  | { kind: "creating" }
  | { kind: "waiting"; code: string; expiresAt: number }
  | { kind: "linked"; label: string }
  | { kind: "expired" }
  | { kind: "failed"; message: string };

/** The signed Mac app, zipped; the site serves it (`sites/axo.leostera.dev/src/install.ts`). */
const MAC_APP_DOWNLOAD = "/cdn/Axo.app.zip";

/**
 * Installs Axo on a Mac from this site and opens `code` in it. Preferred over the download: a
 * browser-downloaded app is quarantined, so Gatekeeper asks about it on first open.
 */
function installCommand(code: string): string {
  return `curl -fsSL '${window.location.origin}/install?code=${code}' | sh`;
}

/** A one-time code for a Mac to redeem; says so when a new Mac shows up on the account. */
function PairMacSheet({ workbench, pairingUrl, onClose }: { workbench: ChatWorkbench; pairingUrl: string; onClose: () => void }) {
  const [pairing, setPairing] = useState<Pairing>({ kind: "creating" });
  const [now, setNow] = useState(Date.now());
  const [copied, setCopied] = useState(false);
  const [copiedInstall, setCopiedInstall] = useState(false);
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
  const copyInstall = async (command: string) => {
    try {
      await navigator.clipboard.writeText(command);
      setCopiedInstall(true);
    } catch {
      setCopiedInstall(false);
    }
  };

  return (
    <Sheet title="Pair a Mac" onClose={onClose}>
      <div className="pairing">
        {pairing.kind === "creating" ? (
          <>
            <AxoMascot className="pairing-mascot" loading />
            <p className="pairing-note">Getting a code…</p>
          </>
        ) : null}
        {pairing.kind === "waiting" ? (
          <>
            <p className="pairing-note">On your Mac, open Axo → Settings → Remote Access, and enter this code under Link this Mac.</p>
            <strong className="pairing-code" aria-label="Pairing code">{pairing.code}</strong>
            <p className="pairing-countdown">Expires in {Math.floor(remaining / 60)}:{String(remaining % 60).padStart(2, "0")}</p>
            <div className="pairing-actions">
              <button className="bordered-button" onClick={() => void copy(pairing.code)}><Icon name={copied ? "check" : "copy"} size={17} /> {copied ? "Copied" : "Copy"}</button>
              <a className="bordered-button" href={`axo://pair/${pairing.code}`}><Icon name="laptop" size={17} /> Open on this Mac</a>
            </div>
            <p className="pairing-waiting"><span className="spinner" aria-hidden="true" /> Waiting for your Mac…</p>
            <div className="pairing-install">
              <p className="pairing-note">No Axo on that Mac yet? The Terminal command installs it, starts it and fills in this code.</p>
              <code className="pairing-command">{installCommand(pairing.code)}</code>
              <div className="pairing-actions">
                <button className="bordered-button" onClick={() => void copyInstall(installCommand(pairing.code))}><Icon name={copiedInstall ? "check" : "terminal"} size={17} /> {copiedInstall ? "Copied" : "Copy command"}</button>
                <a className="bordered-button" href={MAC_APP_DOWNLOAD} download><Icon name="pair" size={17} /> Download Axo</a>
              </div>
            </div>
          </>
        ) : null}
        {pairing.kind === "linked" ? (
          <>
            <AxoMascot className="pairing-mascot" />
            <strong className="pairing-done">{pairing.label} is paired</strong>
            <p className="pairing-note">Its chats are in the menu now.</p>
            <button className="pill-button primary" onClick={onClose}>Done</button>
          </>
        ) : null}
        {pairing.kind === "expired" || pairing.kind === "failed" ? (
          <>
            <strong className="pairing-done">{pairing.kind === "expired" ? "The code expired" : "No code"}</strong>
            <p className="pairing-note">{pairing.kind === "expired" ? "Codes last ten minutes. Get a new one and enter it on your Mac." : pairing.message}</p>
            <button className="pill-button primary" onClick={() => void create()}>Get a new code</button>
          </>
        ) : null}
      </div>
    </Sheet>
  );
}

/** Whether the page is in front of the person: shown and focused, so what it shows is seen. */
function usePageVisible(): boolean {
  const read = () => document.visibilityState === "visible" && document.hasFocus();
  const [visible, setVisible] = useState(read);
  useEffect(() => {
    const update = () => setVisible(read());
    document.addEventListener("visibilitychange", update);
    window.addEventListener("focus", update);
    window.addEventListener("blur", update);
    return () => {
      document.removeEventListener("visibilitychange", update);
      window.removeEventListener("focus", update);
      window.removeEventListener("blur", update);
    };
  }, []);
  return visible;
}
