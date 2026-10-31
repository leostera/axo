import { useCallback, useEffect, useState } from "react";
import { connectionsResults, type CallRecord, type Connection } from "@axo/protocol";
import { Icon } from "./icons.tsx";
import { relativeTime } from "./message-views.tsx";

/**
 * The Connections page (RFD0016): what the account's Sessions reach through `connections_*`.
 * Every paired Mac is a connection; remote MCP servers are added here or by an agent, and signed
 * in to here, as are the apps Axo provides (`codemode.apps.<app>`). A client secret is typed only here, never in a chat, and no grant ever reaches the
 * browser. The recent call log shows what ran, with which input, from which Session.
 */

type Loaded = { connections: Connection[]; records: CallRecord[] };
type Notice = { kind: "ok" | "error"; text: string } | null;

/** What the sign-in callback left in the URL: `?signedIn=<name>` or `?error=<message>`. */
export function signInNotice(search: string): Notice {
  const query = new URLSearchParams(search);
  const signedIn = query.get("signedIn");
  if (signedIn) return { kind: "ok", text: `Signed in to ${signedIn}. Its tools are available to your Sessions.` };
  const error = query.get("error");
  return error ? { kind: "error", text: error.slice(0, 300) } : null;
}

export function ConnectionsView({ connectionsUrl, initialNotice }: { connectionsUrl: string; initialNotice: Notice }) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [notice, setNotice] = useState<Notice>(initialNotice);
  const [busy, setBusy] = useState(false);
  const [adding, setAdding] = useState({ name: "", url: "" });
  const [clientFor, setClientFor] = useState<string | null>(null);
  const [client, setClient] = useState({ clientId: "", clientSecret: "" });

  const load = useCallback(async () => {
    try {
      const [list, log] = await Promise.all([
        request(connectionsUrl, "GET"),
        request(`${connectionsUrl}/log?limit=20`, "GET"),
      ]);
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

  const add = () => act(async () => {
    const result = connectionsResults["axo.connections.add"].parse(await request(connectionsUrl, "POST", adding));
    setAdding({ name: "", url: "" });
    if (result.signInUrl?.includes("/oauth/start")) window.location.assign(result.signInUrl);
    else if (result.connection.kind === "thirdParty" && result.connection.state === "needsSignIn") {
      setClientFor(result.connection.name);
      setNotice({ kind: "error", text: result.connection.lastError ?? `${result.connection.name} needs sign-in.` });
    } else setNotice({ kind: "ok", text: `Added ${result.connection.name}.` });
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

  const disconnect = (name: string, title: string, account: string) => {
    if (!window.confirm(`Sign ${account} out of ${title}? Its grant is deleted and revoked, and scripts can no longer act as it.`)) return;
    void act(async () => {
      await request(`${connectionsUrl}/${encodeURIComponent(name)}/remove`, "POST", { account });
      setNotice({ kind: "ok", text: `Signed ${account} out of ${title}.` });
    });
  };

  const connections = loaded?.connections.filter((connection) => connection.kind !== "app");
  const apps = loaded?.connections.filter((connection) => connection.kind === "app");

  const remove = (name: string) => {
    if (!window.confirm(`Remove ${name}? Its grant is deleted, and scripts can no longer call it.`)) return;
    void act(async () => {
      await request(`${connectionsUrl}/${encodeURIComponent(name)}/remove`, "POST");
      setNotice({ kind: "ok", text: `Removed ${name}.` });
    });
  };

  return (
    <div className="connections">
      {notice ? <p className={notice.kind === "ok" ? "connections-notice" : "connections-notice error"} role="status">{notice.text}</p> : null}
      <h3 className="sheet-section">Connections</h3>
      <div className="grouped">
        {loaded === null ? <p className="grouped-row muted">Loading…</p> : null}
        {connections?.map((connection) => (
          <div key={connection.name} className="grouped-row connection-row">
            <Icon name={connection.kind === "host" ? "laptop" : "plug"} size={18} />
            <span className="connection-copy">
              <strong className="mono">{connection.name}</strong>
              <small>{describe(connection)}</small>
            </span>
            <span className={`mac-dot ${connection.state === "online" || connection.state === "ready" ? "online" : ""}`}
              aria-label={stateName(connection)} title={stateName(connection)} />
            {connection.kind === "thirdParty" && connection.state === "needsSignIn"
              ? <button className="bordered-button" disabled={busy} onClick={() => void signIn(connection.name)}>Sign in</button>
              : null}
            {connection.kind === "thirdParty"
              ? <button className="plain-icon-button" disabled={busy} onClick={() => remove(connection.name)} aria-label={`Remove ${connection.name}`}><Icon name="close" size={16} /></button>
              : null}
          </div>
        ))}
        {connections && connections.length === 0 ? <p className="grouped-row muted">No connections yet. Pair a Mac, or add a server below.</p> : null}
      </div>

      {apps && apps.length > 0 ? (
        <>
          <h3 className="sheet-section">Apps</h3>
          <div className="grouped">
            {apps.map((app) => app.kind === "app" ? (
              <div key={app.name} className="app-group">
                <div className="grouped-row connection-row">
                  <Icon name="mail" size={18} />
                  <span className="connection-copy">
                    <strong>{app.title}</strong>
                    <small>{describe(app)}</small>
                  </span>
                  <button className="bordered-button" disabled={busy} onClick={() => void signIn(app.name)}
                    aria-label={app.accounts.length ? `Add a ${app.title} account` : `Sign in to ${app.title}`}>
                    {app.accounts.length ? "Add account" : "Sign in"}
                  </button>
                </div>
                {app.accounts.map((account) => (
                  <div key={account.account} className="grouped-row connection-row app-account">
                    <span className="connection-copy">
                      <strong className="mono">{account.account}</strong>
                      <small>{account.state === "ready" ? "signed in" : account.lastError ?? "needs sign-in"}</small>
                    </span>
                    <span className={`mac-dot ${account.state === "ready" ? "online" : ""}`} aria-label={account.state === "ready" ? "Ready" : "Needs sign-in"} />
                    {account.state === "needsSignIn"
                      ? <button className="bordered-button" disabled={busy} onClick={() => void signIn(app.name)}>Sign in</button>
                      : null}
                    <button className="plain-icon-button" disabled={busy} onClick={() => disconnect(app.name, app.title, account.account)}
                      aria-label={`Sign ${account.account} out of ${app.title}`}><Icon name="signOut" size={16} /></button>
                  </div>
                ))}
              </div>
            ) : null)}
          </div>
          <p className="sheet-note">Scripts call an app's tools as codemode.apps.&lt;app&gt;.&lt;tool&gt;(&#123; account, … &#125;), naming the account to act as, for example codemode.apps.gmail.search_messages(&#123; account: "you@example.com", query: "is:unread" &#125;).</p>
        </>
      ) : null}

      {clientFor ? (
        <>
          <h3 className="sheet-section">Client for {clientFor}</h3>
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void saveClient(clientFor); }}>
            <input className="grouped-row" required placeholder="Client ID" value={client.clientId} autoComplete="off"
              onChange={(event) => setClient({ ...client, clientId: event.target.value })} aria-label="Client ID" />
            <input className="grouped-row" type="password" placeholder="Client secret, if the provider gave one" value={client.clientSecret} autoComplete="off"
              onChange={(event) => setClient({ ...client, clientSecret: event.target.value })} aria-label="Client secret" />
            <button className="grouped-row" disabled={busy} type="submit">Save and sign in</button>
          </form>
          <p className="sheet-note">This server does not register clients itself. Register an OAuth app with the provider, with redirect URI https://axo.leostera.dev/api/v1/connections/oauth/callback. The secret is stored encrypted and never shown again.</p>
        </>
      ) : null}

      <h3 className="sheet-section">Add a server</h3>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void add(); }}>
        <input className="grouped-row" required pattern="[A-Za-z_][A-Za-z0-9_]{0,63}" placeholder="Name, e.g. linear" value={adding.name}
          onChange={(event) => setAdding({ ...adding, name: event.target.value })} aria-label="Name" autoCapitalize="off" autoCorrect="off" spellCheck={false} />
        <input className="grouped-row" required type="url" pattern="https://.*" placeholder="https://mcp.example.com/mcp" value={adding.url}
          onChange={(event) => setAdding({ ...adding, url: event.target.value })} aria-label="Server URL" />
        <button className="grouped-row" disabled={busy} type="submit">Add</button>
      </form>
      <p className="sheet-note">Scripts call a server's tools as codemode.&lt;name&gt;.&lt;tool&gt;(). Its grant stays in your account's cloud; Macs and Sessions never see it.</p>

      <h3 className="sheet-section">Recent calls</h3>
      <div className="grouped">
        {loaded?.records.map((record) => (
          <div key={record.callId} className="grouped-row call-row" title={JSON.stringify(record.input)}>
            <span className={`call-outcome ${record.outcome}`}>{record.outcome === "ok" ? "✓" : record.outcome === "error" ? "✕" : "?"}</span>
            <span className="connection-copy">
              <strong className="mono">{record.service}.{record.tool}</strong>
              <small className="mono">{summary(record)}</small>
            </span>
            <small className="call-age">{relativeTime(Date.parse(record.at))}</small>
          </div>
        ))}
        {loaded && loaded.records.length === 0 ? <p className="grouped-row muted">No calls in the last 30 days.</p> : null}
      </div>
      <p className="sheet-note">Calls are kept for 30 days with their inputs, encrypted; outputs are never kept.</p>
    </div>
  );
}

function describe(connection: Connection): string {
  if (connection.kind === "host") return connection.state === "online" ? "Mac · bash" : "Mac · offline";
  if (connection.kind === "app") {
    const accounts = connection.accounts.length === 1 ? "1 account" : `${connection.accounts.length || "no"} accounts`;
    return `${connection.name} · ${accounts} · ${connection.tools.length} tools`;
  }
  const tools = connection.tools === 1 ? "1 tool" : `${connection.tools} tools`;
  if (connection.state === "needsSignIn") return `${new URL(connection.url).host} · needs sign-in`;
  if (connection.state === "error") return `${new URL(connection.url).host} · ${connection.lastError ?? "unreachable"}`;
  return `${new URL(connection.url).host} · ${tools}`;
}

function stateName(connection: Connection): string {
  return { online: "Online", offline: "Offline", ready: "Ready", needsSignIn: "Needs sign-in", error: "Error" }[connection.state];
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
