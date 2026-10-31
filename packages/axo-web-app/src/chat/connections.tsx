import { useCallback, useEffect, useState, type ReactNode } from "react";
import { connectionsResults, type CallRecord, type Connection } from "@axo/protocol";
import { Icon, type IconName } from "./icons.tsx";
import { relativeTime } from "./message-views.tsx";
import type { SettingsRoute } from "./route.ts";

/**
 * Settings › Apps (RFD0016): what the account's Sessions can use, as pages over the chats, each
 * with its own URL. Apps lists the apps Axo provides, then MCP servers and activity. An app's
 * page says what it is for and what it may do, lists its accounts with Add account, and shows
 * what Sessions did with it. A client secret is typed only here, never in a chat, and no grant
 * ever reaches the browser.
 */

type App = Extract<Connection, { kind: "app" }>;
type Server = Extract<Connection, { kind: "thirdParty" }>;
type Notice = { kind: "ok" | "error"; text: string } | null;

/** What the sign-in callback left in the URL, `?signedIn=<name>` or `?error=<message>`, as a notice. */
export function signInNotice(search: string): Notice {
  const query = new URLSearchParams(search);
  const signedIn = query.get("signedIn");
  if (signedIn?.startsWith("apps.")) return { kind: "ok", text: "Account added." };
  if (signedIn) return { kind: "ok", text: `Signed in to ${signedIn}.` };
  const error = query.get("error");
  return error ? { kind: "error", text: error.slice(0, 300) } : null;
}

/** The page a sign-in that came back to `<base>/connections` belongs on. */
export function signInPage(search: string): SettingsRoute {
  const signedIn = new URLSearchParams(search).get("signedIn");
  if (signedIn?.startsWith("apps.")) return { kind: "app", app: signedIn.slice("apps.".length) };
  return signedIn ? { kind: "servers" } : { kind: "apps" };
}

export function AppsSettings({ connectionsUrl, route, initialNotice, onNavigate, onClose }: {
  connectionsUrl: string;
  route: SettingsRoute;
  initialNotice: Notice;
  onNavigate: (route: SettingsRoute) => void;
  onClose: () => void;
}) {
  const [connections, setConnections] = useState<Connection[] | null>(null);
  const [notice, setNotice] = useState<Notice>(initialNotice);
  const [busy, setBusy] = useState(false);
  const [version, setVersion] = useState(0);

  const load = useCallback(async () => {
    try {
      setConnections(connectionsResults["axo.connections.list"].parse(await request(connectionsUrl, "GET")).connections);
    } catch (error) {
      setNotice({ kind: "error", text: message(error) });
    }
  }, [connectionsUrl]);
  useEffect(() => { void load(); }, [load]);

  const act = async (work: () => Promise<void>) => {
    setBusy(true);
    try {
      await work();
    } catch (error) {
      setNotice({ kind: "error", text: message(error) });
    } finally {
      setBusy(false);
      setVersion((v) => v + 1);
      void load();
    }
  };

  const go = (next: SettingsRoute) => {
    setNotice(null);
    onNavigate(next);
  };
  const back = () => (route.kind === "apps" ? onClose() : go({ kind: "apps" }));

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !(event.target instanceof HTMLInputElement)) back();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  const apps = (connections ?? []).filter((c): c is App => c.kind === "app");
  const servers = (connections ?? []).filter((c): c is Server => c.kind === "thirdParty");
  const shared: Shared = { connectionsUrl, busy, act, setNotice };

  let title = "Apps";
  let body: ReactNode;
  if (route.kind === "app") {
    const app = apps.find((a) => a.name === `apps.${route.app}`);
    title = app?.title ?? "App";
    body = app ? <AppPage key={app.name} app={app} version={version} {...shared} /> : <p className="settings-muted">{connections ? "This app is not available." : "Loading…"}</p>;
  } else if (route.kind === "servers") {
    title = "MCP servers";
    body = <div className="settings-narrow"><ServersPage servers={servers} loaded={connections !== null} {...shared} /></div>;
  } else if (route.kind === "activity") {
    title = "Activity";
    body = <div className="settings-narrow"><ActivityPage connectionsUrl={connectionsUrl} /></div>;
  } else {
    body = <AppsHome apps={apps} servers={servers} loaded={connections !== null} connectionsUrl={connectionsUrl} go={go} />;
  }

  return (
    <div className="settings-page" role="region" aria-label={title}>
      <header className="settings-bar">
        <button className="circle-button" onClick={back} aria-label="Back"><Icon name="chevronLeft" size={16} /></button>
        <nav className="settings-crumbs" aria-label="Breadcrumb">
          <span>Settings</span>
          <Icon name="chevronRight" size={12} />
          {route.kind === "apps" ? <span aria-current="page">Apps</span> : <button className="link" onClick={() => go({ kind: "apps" })}>Apps</button>}
          {route.kind !== "apps" ? <><Icon name="chevronRight" size={12} /><span aria-current="page">{title}</span></> : null}
        </nav>
        <button className="circle-button" onClick={onClose} aria-label="Close settings"><Icon name="close" size={16} /></button>
      </header>
      <div className="settings-body">
        {notice ? <p className={notice.kind === "ok" ? "connections-notice" : "connections-notice error"} role="status">{notice.text}</p> : null}
        <div className="connections">{body}</div>
      </div>
    </div>
  );
}

const CATEGORY_TITLES: Record<string, string> = {
  communication: "Communication", productivity: "Productivity", files: "Files", developer: "Developer",
  other: "Other", finance: "Finance", social: "Social", travel: "Travel", shopping: "Shopping", entertainment: "Entertainment", health: "Health", home: "Home",
};
type Status = "all" | "connected" | "notConnected";

/** Apps: filters, a grid of every app and MCP server, and what Sessions used lately. */
function AppsHome({ apps, servers, loaded, connectionsUrl, go }: {
  apps: App[]; servers: Server[]; loaded: boolean; connectionsUrl: string; go: (route: SettingsRoute) => void;
}) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<Status>("all");
  const [category, setCategory] = useState<string>("all");

  type Tile = { key: string; title: string; subtitle: string; connected: boolean; category: string; provider: string; look: ReactNode; open: () => void; detail: string };
  const tiles: Tile[] = [
    ...apps.map((app): Tile => ({
      key: app.name, title: app.title, subtitle: app.description, category: app.category || "other", provider: app.provider,
      connected: app.accounts.some((a) => a.state === "ready"), look: <AppTile app={app.name} large />,
      detail: count(app.accounts.length, "account"), open: () => go({ kind: "app", app: app.name.slice("apps.".length) }),
    })),
    ...servers.map((server): Tile => ({
      key: server.name, title: server.name, subtitle: host(server.url), category: "mcp", provider: "MCP",
      connected: server.state === "ready", look: <span className="app-tile large neutral"><Icon name="plug" size={28} /></span>,
      detail: server.state === "ready" ? count(server.tools, "tool") : server.state === "needsSignIn" ? "Needs sign-in" : "Unreachable",
      open: () => go({ kind: "servers" }),
    })),
  ];
  const categories = [...new Set(tiles.map((t) => t.category))];
  const needle = query.trim().toLowerCase();
  const shown = tiles.filter((t) =>
    (status === "all" || (status === "connected") === t.connected)
    && (category === "all" || t.category === category)
    && (!needle || `${t.title} ${t.subtitle} ${t.provider}`.toLowerCase().includes(needle)));
  const countOf = (filter: (t: Tile) => boolean) => tiles.filter(filter).length;

  return (
    <div className="apps-layout">
      <aside className="apps-filters" aria-label="Filters">
        <input className="apps-search" type="search" placeholder="Search apps" value={query} onChange={(event) => setQuery(event.target.value)} aria-label="Search apps" />
        <h2 className="settings-section">Status</h2>
        <div className="filter-list" role="radiogroup" aria-label="Status">
          {([["all", "All"], ["connected", "Connected"], ["notConnected", "Not connected"]] as const).map(([value, label]) => (
            <FilterChip key={value} label={label} count={countOf((t) => value === "all" || (value === "connected") === t.connected)} selected={status === value} onClick={() => setStatus(value)} />
          ))}
        </div>
        <h2 className="settings-section">Category</h2>
        <div className="filter-list" role="radiogroup" aria-label="Category">
          <FilterChip label="All" count={tiles.length} selected={category === "all"} onClick={() => setCategory("all")} />
          {categories.map((c) => (
            <FilterChip key={c} label={c === "mcp" ? "MCP servers" : CATEGORY_TITLES[c] ?? c} count={countOf((t) => t.category === c)} selected={category === c} onClick={() => setCategory(c)} />
          ))}
        </div>
      </aside>

      <section className="apps-grid-column" aria-label="All apps">
        <div className="apps-grid">
          {!loaded ? <p className="settings-muted">Loading…</p> : null}
          {shown.map((tile) => (
            <button key={tile.key} className="app-card" onClick={tile.open}>
              {tile.look}
              <strong>{tile.title}</strong>
              <small className={tile.connected ? "connected" : ""}>{tile.connected ? <span className="mac-dot online" aria-hidden="true" /> : null}{tile.detail}</small>
            </button>
          ))}
          {loaded && status === "all" && (category === "all" || category === "mcp") && !needle ? (
            <button className="app-card add-card" onClick={() => go({ kind: "servers" })}>
              <span className="app-tile large neutral"><Icon name="plug" size={28} /></span>
              <strong>Add MCP server</strong>
              <small>Any server with a URL</small>
            </button>
          ) : null}
          {loaded && shown.length === 0 && needle ? <p className="settings-muted">No app matches “{query}”.</p> : null}
        </div>
      </section>

      <aside className="apps-activity" aria-label="Recent activity">
        <div className="apps-activity-head">
          <h2 className="settings-section">Recent activity</h2>
          <button className="link" onClick={() => go({ kind: "activity" })}>See all</button>
        </div>
        <Integrity connectionsUrl={connectionsUrl} />
        <Calls connectionsUrl={connectionsUrl} limit={12} compact />
      </aside>
    </div>
  );
}

function FilterChip({ label, count, selected, onClick }: { label: string; count: number; selected: boolean; onClick: () => void }) {
  return (
    <button className={`filter-chip${selected ? " selected" : ""}`} role="radio" aria-checked={selected} onClick={onClick}>
      <span>{label}</span><small>{count}</small>
    </button>
  );
}

/** Whether the call log is as it was written: its hash chain, replayed in the cloud. */
function Integrity({ connectionsUrl }: { connectionsUrl: string }) {
  const [check, setCheck] = useState<{ verified: boolean; events: number; head: string | null; reason: string | null } | null | "failed">(null);
  useEffect(() => {
    let live = true;
    request(`${connectionsUrl}/log/integrity`, "GET")
      .then((answer) => { if (live) setCheck(answer as { verified: boolean; events: number; head: string | null; reason: string | null }); })
      .catch(() => { if (live) setCheck("failed"); });
    return () => { live = false; };
  }, [connectionsUrl]);
  if (check === null || check === "failed") return null;
  return (
    <p className={`integrity${check.verified ? "" : " broken"}`} title={check.head ? `Chain head ${check.head}` : undefined}>
      <Icon name={check.verified ? "check" : "warning"} size={14} />
      {check.verified ? `Log intact · ${count(check.events, "entry", "entries")}` : `Log was changed: ${check.reason ?? "unknown"}`}
    </p>
  );
}

type Shared = {
  connectionsUrl: string;
  busy: boolean;
  act: (work: () => Promise<void>) => Promise<void>;
  setNotice: (notice: Notice) => void;
};

function AppPage({ app, version, connectionsUrl, busy, act, setNotice }: Shared & { app: App; version: number }) {
  const add = () => act(async () => {
    const { signInUrl } = (await request(`${connectionsUrl}/${encodeURIComponent(app.name)}/sign-in`, "POST")) as { signInUrl: string };
    window.location.assign(signInUrl);
  });
  const signOut = (account: string) => {
    if (!window.confirm(`Remove ${account} from ${app.title}? Your Sessions can no longer use it, and Axo's access is revoked at Google.`)) return;
    void act(async () => {
      await request(`${connectionsUrl}/${encodeURIComponent(app.name)}/remove`, "POST", { account });
      setNotice({ kind: "ok", text: `Removed ${account}.` });
    });
  };
  return (
    <div className="app-layout">
      <aside className="app-info">
        <AppTile app={app.name} large />
        <h1>{app.title}</h1>
        {app.provider || app.category
          ? <p className="app-meta">{[app.provider, app.category ? CATEGORY_TITLES[app.category] ?? app.category : ""].filter(Boolean).join(" · ")}</p>
          : null}
        {app.description ? <p>{app.description}</p> : null}
      </aside>

      <section className="app-main">
        <h2 className="settings-section">Accounts</h2>
        <div className="grouped">
          {app.accounts.map((account) => (
            <div key={account.account} className="grouped-row connection-row">
              <Icon name="person" size={18} />
              <span className="connection-copy">
                <strong>{account.account}</strong>
                {account.state === "needsSignIn" ? <small>Needs sign-in</small> : null}
              </span>
              {account.state === "needsSignIn"
                ? <button className="bordered-button" disabled={busy} onClick={() => void add()}>Sign in</button>
                : <span className="mac-dot online" aria-label="Connected" title="Connected" />}
              <button className="plain-icon-button" disabled={busy} onClick={() => signOut(account.account)} aria-label={`Remove ${account.account}`}>
                <Icon name="close" size={16} />
              </button>
            </div>
          ))}
          <button className="grouped-row add-row" disabled={busy} onClick={() => void add()}>Add account</button>
        </div>

        {app.permissions.length ? <h2 className="settings-section">What Axo can do</h2> : null}
        <ul className="grouped permissions" hidden={!app.permissions.length}>
          {app.permissions.map((permission) => (
            <li key={permission} className="grouped-row"><Icon name="check" size={16} /><span>{permission}</span></li>
          ))}
        </ul>
        {app.permissions.length ? <p className="sheet-note">Only with the accounts above, and only when one of your Sessions asks.</p> : null}
      </section>

      <aside className="app-activity">
        <h2 className="settings-section">Recent activity</h2>
        <Calls connectionsUrl={connectionsUrl} service={app.name} version={version} />
      </aside>
    </div>
  );
}

function ServersPage({ servers, loaded, connectionsUrl, busy, act, setNotice }: Shared & { servers: Server[]; loaded: boolean }) {
  const [adding, setAdding] = useState<{ name: string; url: string } | null>(null);
  const [clientFor, setClientFor] = useState<string | null>(null);
  const [client, setClient] = useState({ clientId: "", clientSecret: "" });

  const add = (draft: { name: string; url: string }) => act(async () => {
    const result = connectionsResults["axo.connections.add"].parse(await request(connectionsUrl, "POST", draft));
    setAdding(null);
    if (result.signInUrl?.includes("/oauth/start")) window.location.assign(result.signInUrl);
    else if (result.connection.kind === "thirdParty" && result.connection.state === "needsSignIn") setClientFor(result.connection.name);
    else setNotice({ kind: "ok", text: `Added ${result.connection.name}.` });
  });
  const signIn = (name: string) => act(async () => {
    const { signInUrl } = (await request(`${connectionsUrl}/${encodeURIComponent(name)}/sign-in`, "POST")) as { signInUrl: string };
    if (signInUrl.includes("/oauth/start")) window.location.assign(signInUrl);
    else setClientFor(name);
  });
  const saveClient = (name: string) => act(async () => {
    const body = { clientId: client.clientId.trim(), clientSecret: client.clientSecret.trim() || null };
    const { signInUrl } = (await request(`${connectionsUrl}/${encodeURIComponent(name)}/client`, "POST", body)) as { signInUrl: string };
    setClient({ clientId: "", clientSecret: "" });
    setClientFor(null);
    if (signInUrl.includes("/oauth/start")) window.location.assign(signInUrl);
  });
  const remove = (name: string) => {
    if (!window.confirm(`Remove ${name}? Your Sessions can no longer use it.`)) return;
    void act(async () => {
      await request(`${connectionsUrl}/${encodeURIComponent(name)}/remove`, "POST");
      setNotice({ kind: "ok", text: `Removed ${name}.` });
    });
  };

  return (
    <>
      <header className="settings-hero">
        <h1>MCP servers</h1>
        <p>Add any MCP server, and your Sessions can use its tools.</p>
      </header>
      <div className="grouped">
        {!loaded ? <p className="grouped-row muted">Loading…</p> : null}
        {servers.map((server) => (
          <div key={server.name} className="grouped-row connection-row">
            <Icon name="plug" size={18} />
            <span className="connection-copy">
              <strong>{server.name}</strong>
              <small>{host(server.url)}{server.state === "needsSignIn" ? " · needs sign-in" : server.state === "error" ? " · unreachable" : ""}</small>
            </span>
            {server.state === "needsSignIn"
              ? <button className="bordered-button" disabled={busy} onClick={() => void signIn(server.name)}>Sign in</button>
              : <span className={`mac-dot ${server.state === "ready" ? "online" : ""}`} aria-label={server.state === "ready" ? "Connected" : "Error"} />}
            <button className="plain-icon-button" disabled={busy} onClick={() => remove(server.name)} aria-label={`Remove ${server.name}`}><Icon name="close" size={16} /></button>
          </div>
        ))}
        {adding === null ? <button className="grouped-row add-row" disabled={busy} onClick={() => setAdding({ name: "", url: "" })}>Add server</button> : null}
      </div>

      {adding !== null ? (
        <>
          <h2 className="settings-section">Add server</h2>
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void add(adding); }}>
            <input className="grouped-row" required pattern="[A-Za-z_][A-Za-z0-9_]{0,63}" placeholder="Name, e.g. linear" value={adding.name} autoFocus
              onChange={(event) => setAdding({ ...adding, name: event.target.value })} aria-label="Name" autoCapitalize="off" autoCorrect="off" spellCheck={false} />
            <input className="grouped-row" required type="url" pattern="https://.*" placeholder="https://mcp.example.com/mcp" value={adding.url}
              onChange={(event) => setAdding({ ...adding, url: event.target.value })} aria-label="Server URL" />
            <button className="grouped-row" disabled={busy} type="submit">Add</button>
          </form>
        </>
      ) : null}

      {clientFor ? (
        <>
          <h2 className="settings-section">Sign in to {clientFor}</h2>
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void saveClient(clientFor); }}>
            <input className="grouped-row" required placeholder="Client ID" value={client.clientId} autoComplete="off"
              onChange={(event) => setClient({ ...client, clientId: event.target.value })} aria-label="Client ID" />
            <input className="grouped-row" type="password" placeholder="Client secret, if there is one" value={client.clientSecret} autoComplete="off"
              onChange={(event) => setClient({ ...client, clientSecret: event.target.value })} aria-label="Client secret" />
            <button className="grouped-row" disabled={busy} type="submit">Save and sign in</button>
          </form>
          <p className="sheet-note">This server needs an OAuth app you create with its provider, with redirect URI https://axo.leostera.dev/api/v1/connections/oauth/callback.</p>
        </>
      ) : null}
    </>
  );
}

function ActivityPage({ connectionsUrl }: { connectionsUrl: string }) {
  return (
    <>
      <header className="settings-hero">
        <h1>Activity</h1>
        <p>What your Sessions used in the last 30 days.</p>
      </header>
      <Integrity connectionsUrl={connectionsUrl} />
      <Calls connectionsUrl={connectionsUrl} />
    </>
  );
}

/** Recent calls, of every app and server or of one. */
function Calls({ connectionsUrl, service, version = 0, limit, compact = false }: { connectionsUrl: string; service?: string; version?: number; limit?: number; compact?: boolean }) {
  const [records, setRecords] = useState<CallRecord[] | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    const query = new URLSearchParams({ limit: String(limit ?? (service ? 20 : 50)), ...(service ? { service } : {}) });
    request(`${connectionsUrl}/log?${query}`, "GET")
      .then((log) => { if (live) setRecords(connectionsResults["axo.connections.log"].parse(log).records); })
      .catch(() => { if (live) setFailed(true); });
    return () => { live = false; };
  }, [connectionsUrl, service, version, limit]);
  return (
    <div className={`grouped${compact ? " compact-calls" : ""}`}>
      {records === null ? <p className="grouped-row muted">{failed ? "Activity is unavailable." : "Loading…"}</p> : null}
      {records?.map((record) => (
        <div key={record.callId} className="grouped-row call-row" title={JSON.stringify(record.input)}>
          <span className={`call-outcome ${record.outcome}`}>{record.outcome === "ok" ? "✓" : record.outcome === "error" ? "✕" : "?"}</span>
          <span className="connection-copy">
            <strong>{callTitle(record, service !== undefined)}</strong>
            <small>{summary(record)}</small>
          </span>
          <small className="call-age">{relativeTime(Date.parse(record.at))}</small>
        </div>
      ))}
      {records && records.length === 0 ? <p className="grouped-row muted">Nothing yet.</p> : null}
    </div>
  );
}

const APP_LOOKS: Record<string, { icon: IconName; color: string }> = {
  "apps.gmail": { icon: "mail", color: "#ea4335" },
  "apps.calendar": { icon: "calendar", color: "#4285f4" },
  "apps.drive": { icon: "folder", color: "#1fa463" },
  "apps.docs": { icon: "doc", color: "#2684fc" },
  "apps.sheets": { icon: "table", color: "#0f9d58" },
  "apps.slides": { icon: "presentation", color: "#f4b400" },
  "apps.contacts": { icon: "contacts", color: "#1a73e8" },
  "apps.tasks": { icon: "checklist", color: "#2563eb" },
  "apps.meet": { icon: "video", color: "#00897b" },
  "apps.cloud": { icon: "cloud", color: "#4285f4" },
};

function AppTile({ app, large = false }: { app: string; large?: boolean }) {
  const look = APP_LOOKS[app] ?? { icon: "plug" as IconName, color: "var(--gray)" };
  return (
    <span className={`app-tile${large ? " large" : ""}`} style={{ background: look.color }} aria-hidden="true">
      <Icon name={look.icon} size={large ? 30 : 18} />
    </span>
  );
}

function count(n: number, noun: string, nouns = `${noun}s`): string {
  return n === 0 ? `No ${nouns}` : n === 1 ? `1 ${noun}` : `${n} ${nouns}`;
}

function host(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

const SERVICE_TITLES: Record<string, string> = {
  "apps.gmail": "Gmail", "apps.calendar": "Calendar", "apps.drive": "Drive", "apps.docs": "Docs", "apps.sheets": "Sheets",
  "apps.slides": "Slides", "apps.contacts": "Contacts", "apps.tasks": "Tasks", "apps.meet": "Meet", "apps.cloud": "Google Cloud",
};

/** "Search messages", or with its app or server first: "Gmail · Search messages". */
export function callTitle(record: Pick<CallRecord, "service" | "tool">, ofOne: boolean): string {
  const words = record.tool.replace(/_/g, " ");
  const tool = words.charAt(0).toUpperCase() + words.slice(1);
  return ofOne ? tool : `${SERVICE_TITLES[record.service] ?? record.service} · ${tool}`;
}

/** What a call was about, in a line: the command a Mac ran, or an app call's account and values. */
export function summary(record: Pick<CallRecord, "input" | "error">): string {
  const input = record.input;
  let what: string;
  if (input && typeof input === "object" && !Array.isArray(input)) {
    const { command, account, ...rest } = input as Record<string, unknown>;
    if (typeof command === "string") what = command;
    else {
      const values = Object.values(rest)
        .filter((v) => v !== null && v !== undefined && v !== "")
        .map((v) => (typeof v === "string" || typeof v === "number" || typeof v === "boolean" ? String(v) : JSON.stringify(v)));
      what = [typeof account === "string" ? account : null, ...values].filter(Boolean).join(" · ");
    }
  } else what = input === null || input === undefined ? "" : JSON.stringify(input);
  const line = what.replace(/\s+/g, " ").slice(0, 100);
  return record.error ? `${line}${line ? " · " : ""}${record.error.slice(0, 80)}` : line;
}

async function request(url: string, method: "GET" | "POST", body?: unknown): Promise<unknown> {
  const response = await fetch(url, {
    method,
    credentials: "include",
    cache: "no-store",
    headers: body === undefined ? { Accept: "application/json" } : { Accept: "application/json", "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const payload = (await response.json().catch(() => null)) as { error?: string } | null;
  if (!response.ok) throw new Error(payload?.error ?? `Request failed (${response.status})`);
  return payload;
}

/** An error as one line for a person: a reply that did not parse is not shown as the parser's report. */
export function message(error: unknown): string {
  if (error instanceof Error && error.name === "ZodError") {
    console.error(error);
    return "Axo answered in a way this page does not understand. Reload the page; if it keeps happening, it is a bug.";
  }
  return error instanceof Error ? error.message : "Something went wrong";
}
