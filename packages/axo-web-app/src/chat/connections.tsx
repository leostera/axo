import { useCallback, useEffect, useState, type ReactNode } from "react";
import { connectionsResults, type CallRecord, type Connection } from "@axo/protocol";
import { Icon, type IconName } from "./icons.tsx";
import { relativeTime } from "./message-views.tsx";

/**
 * The Apps sheet (RFD0016): what the account's Sessions can use. The first page lists the apps
 * Axo provides (Gmail) and MCP servers, then recent activity; each opens a page of its own,
 * where accounts are added and servers signed in to. A client secret is typed only here, never
 * in a chat, and no grant ever reaches the browser.
 */

type App = Extract<Connection, { kind: "app" }>;
type Server = Extract<Connection, { kind: "thirdParty" }>;
type Loaded = { connections: Connection[]; records: CallRecord[] };
type Notice = { kind: "ok" | "error"; text: string } | null;
export type AppsPage = { kind: "home" } | { kind: "app"; name: string } | { kind: "servers" } | { kind: "activity" };

/** What the sign-in callback left in the URL: `?signedIn=<name>` or `?error=<message>`, and which page it belongs on. */
export function signInNotice(search: string): { notice: Notice; page: AppsPage } | null {
  const query = new URLSearchParams(search);
  const signedIn = query.get("signedIn");
  if (signedIn?.startsWith("apps.")) return { notice: { kind: "ok", text: "Account added." }, page: { kind: "app", name: signedIn } };
  if (signedIn) return { notice: { kind: "ok", text: `Signed in to ${signedIn}.` }, page: { kind: "servers" } };
  const error = query.get("error");
  return error ? { notice: { kind: "error", text: error.slice(0, 300) }, page: { kind: "home" } } : null;
}

export function AppsSheet({ connectionsUrl, initial, onClose, Sheet }: {
  connectionsUrl: string;
  initial: { notice: Notice; page: AppsPage } | null;
  onClose: () => void;
  Sheet: (props: { title: string; onClose: () => void; onBack?: () => void; children: ReactNode }) => ReactNode;
}) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [page, setPage] = useState<AppsPage>(initial?.page ?? { kind: "home" });
  const [notice, setNotice] = useState<Notice>(initial?.notice ?? null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const [list, log] = await Promise.all([request(connectionsUrl, "GET"), request(`${connectionsUrl}/log?limit=30`, "GET")]);
      setLoaded({
        connections: connectionsResults["axo.connections.list"].parse(list).connections,
        records: connectionsResults["axo.connections.log"].parse(log).records,
      });
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
      void load();
    }
  };

  const go = (next: AppsPage) => {
    setNotice(null);
    setPage(next);
  };

  const apps = (loaded?.connections ?? []).filter((c): c is App => c.kind === "app");
  const servers = (loaded?.connections ?? []).filter((c): c is Server => c.kind === "thirdParty");
  const shared = { connectionsUrl, busy, act, setNotice };

  let title = "Apps";
  let body: ReactNode;
  if (page.kind === "app") {
    const app = apps.find((a) => a.name === page.name);
    title = app?.title ?? "App";
    body = app ? <AppPage app={app} {...shared} /> : <Loading loaded={loaded} />;
  } else if (page.kind === "servers") {
    title = "MCP servers";
    body = <ServersPage servers={servers} loaded={loaded !== null} {...shared} />;
  } else if (page.kind === "activity") {
    title = "Activity";
    body = <ActivityPage records={loaded?.records ?? null} />;
  } else {
    body = (
      <>
        <div className="grouped">
          {apps.map((app) => (
            <Row key={app.name} icon={iconOf(app.name)} title={app.title} detail={count(app.accounts.length, "account")} onClick={() => go({ kind: "app", name: app.name })} />
          ))}
          <Row icon="plug" title="MCP servers" detail={loaded ? count(servers.length, "server") : ""} onClick={() => go({ kind: "servers" })} />
        </div>
        <div className="grouped">
          <Row icon="doc" title="Activity" detail="What your Sessions used" onClick={() => go({ kind: "activity" })} />
        </div>
      </>
    );
  }

  return (
    <Sheet title={title} onClose={onClose} onBack={page.kind === "home" ? undefined : () => go({ kind: "home" })}>
      <div className="connections">
        {notice ? <p className={notice.kind === "ok" ? "connections-notice" : "connections-notice error"} role="status">{notice.text}</p> : null}
        {body}
      </div>
    </Sheet>
  );
}

type Shared = {
  connectionsUrl: string;
  busy: boolean;
  act: (work: () => Promise<void>) => Promise<void>;
  setNotice: (notice: Notice) => void;
};

function AppPage({ app, connectionsUrl, busy, act, setNotice }: Shared & { app: App }) {
  const add = () => act(async () => {
    const { signInUrl } = (await request(`${connectionsUrl}/${encodeURIComponent(app.name)}/sign-in`, "POST")) as { signInUrl: string };
    window.location.assign(signInUrl);
  });
  const signOut = (account: string) => {
    if (!window.confirm(`Remove ${account} from ${app.title}? Your Sessions can no longer use it.`)) return;
    void act(async () => {
      await request(`${connectionsUrl}/${encodeURIComponent(app.name)}/remove`, "POST", { account });
      setNotice({ kind: "ok", text: `Removed ${account}.` });
    });
  };
  return (
    <>
      <h3 className="sheet-section">Accounts</h3>
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
    </>
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
          <h3 className="sheet-section">Add server</h3>
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
          <h3 className="sheet-section">Sign in to {clientFor}</h3>
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

function ActivityPage({ records }: { records: CallRecord[] | null }) {
  return (
    <div className="grouped">
      {records === null ? <p className="grouped-row muted">Loading…</p> : null}
      {records?.map((record) => (
        <div key={record.callId} className="grouped-row call-row" title={JSON.stringify(record.input)}>
          <span className={`call-outcome ${record.outcome}`}>{record.outcome === "ok" ? "✓" : record.outcome === "error" ? "✕" : "?"}</span>
          <span className="connection-copy">
            <strong className="mono">{record.service}.{record.tool}</strong>
            <small className="mono">{summary(record)}</small>
          </span>
          <small className="call-age">{relativeTime(Date.parse(record.at))}</small>
        </div>
      ))}
      {records && records.length === 0 ? <p className="grouped-row muted">Nothing yet.</p> : null}
    </div>
  );
}

function Row({ icon, title, detail, onClick }: { icon: IconName; title: string; detail: string; onClick: () => void }) {
  return (
    <button className="grouped-row connection-row nav-row" onClick={onClick}>
      <Icon name={icon} size={18} />
      <span className="connection-copy"><strong>{title}</strong></span>
      <small className="nav-detail">{detail}</small>
      <Icon name="chevronRight" size={16} />
    </button>
  );
}

function Loading({ loaded }: { loaded: Loaded | null }) {
  return <p className="grouped-row muted">{loaded ? "This app is not available." : "Loading…"}</p>;
}

const APP_ICONS: Record<string, IconName> = {
  "apps.gmail": "mail",
  "apps.calendar": "calendar",
  "apps.drive": "folder",
  "apps.docs": "doc",
  "apps.sheets": "table",
  "apps.contacts": "contacts",
};

function iconOf(app: string): IconName {
  return APP_ICONS[app] ?? "plug";
}

function count(n: number, noun: string): string {
  return n === 0 ? `No ${noun}s` : n === 1 ? `1 ${noun}` : `${n} ${noun}s`;
}

function host(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

function summary(record: CallRecord): string {
  const input = record.input as { command?: string } | null;
  const what = typeof input?.command === "string" ? input.command : JSON.stringify(record.input);
  return `${what.slice(0, 80)}${record.error ? ` · ${record.error.slice(0, 80)}` : ""}`;
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

function message(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong";
}
