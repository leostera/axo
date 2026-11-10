import { useCallback, useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { appDeviceSignInSchema, appLinkSchema, appMacSignInSchema, appPhoneSignInSchema, appsResults, type AppDeviceSignIn, type AppLink, type AppPhoneSignIn, type CallRecord, type AccountApp } from "@axo/protocol";
import QRCode from "qrcode";
import { Icon } from "./icons.tsx";
import { relativeTime } from "./message-views.tsx";
import type { SettingsRoute } from "./route.ts";
import { KNOWN_SERVERS, knownServerOf, type KnownServer } from "./servers.ts";
import calendarLogo from "./logos/calendar.svg";
import chatgptLogo from "./logos/chatgpt.svg";
import cloudLogo from "./logos/cloud.svg";
import contactsLogo from "./logos/contacts.svg";
import discordLogo from "./logos/discord.svg";
import docsLogo from "./logos/docs.svg";
import driveLogo from "./logos/drive.svg";
import githubLogo from "./logos/github.svg";
import gmailLogo from "./logos/gmail.svg";
import hetznerLogo from "./logos/hetzner.svg";
import krakenLogo from "./logos/kraken.svg";
import meetLogo from "./logos/meet.svg";
import octopusLogo from "./logos/octopus.svg";
import onepasswordLogo from "./logos/onepassword.svg";
import sheetsLogo from "./logos/sheets.svg";
import slidesLogo from "./logos/slides.svg";
import spotifyLogo from "./logos/spotify.svg";
import tasksLogo from "./logos/tasks.svg";
import telegramLogo from "./logos/telegram.svg";
import unifiLogo from "./logos/unifi.svg";
import wiseLogo from "./logos/wise.svg";
import whatsappLogo from "./logos/whatsapp.svg";
import withingsLogo from "./logos/withings.svg";

/**
 * Settings › Apps (RFD0016): what the account's Sessions can use, as pages over the chats, each
 * with its own URL. Apps lists the apps Axo provides, then MCP servers and activity. An app's
 * page says what it is for and what it may do, lists its accounts with Add account, and shows
 * what Sessions did with it. A client secret or an app's token is typed only here, never in a
 * chat, and no grant or token ever reaches the browser again.
 */

type App = Extract<AccountApp, { kind: "app" }>;
type Server = Extract<AccountApp, { kind: "thirdParty" }>;
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

/** The page a sign-in that came back to `<base>/apps` belongs on. */
export function signInPage(search: string): SettingsRoute {
  const signedIn = new URLSearchParams(search).get("signedIn");
  if (signedIn?.startsWith("apps.")) return { kind: "app", app: signedIn.slice("apps.".length) };
  return signedIn ? { kind: "servers" } : { kind: "apps" };
}

export function AppsSettings({ appsUrl, route, initialNotice, onNavigate, onClose, hrefOf }: {
  appsUrl: string;
  route: SettingsRoute;
  initialNotice: Notice;
  onNavigate: (route: SettingsRoute) => void;
  onClose: () => void;
  /** The URL of a settings page, so its links open in a new tab too. */
  hrefOf: (route: SettingsRoute) => string;
}) {
  const [entries, setEntries] = useState<AccountApp[] | null>(null);
  const [notice, setNotice] = useState<Notice>(initialNotice);
  const [busy, setBusy] = useState(false);
  const [version, setVersion] = useState(0);

  const load = useCallback(async () => {
    try {
      setEntries(appsResults["axo.apps.list"].parse(await request(appsUrl, "GET")).apps);
    } catch (error) {
      setNotice({ kind: "error", text: message(error) });
    }
  }, [appsUrl]);
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
  const link = linkTo(go, hrefOf);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !(event.target instanceof HTMLInputElement)) back();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  const apps = (entries ?? []).filter((c): c is App => c.kind === "app");
  const servers = (entries ?? []).filter((c): c is Server => c.kind === "thirdParty");
  const macs = (entries ?? []).flatMap((c) => (c.kind === "host" ? [{ name: c.name, online: c.state === "online" }] : []));
  const shared: Shared = { appsUrl, busy, act, setNotice };

  let title = "Apps";
  let body: ReactNode;
  if (route.kind === "app") {
    const app = apps.find((a) => a.name === `apps.${route.app}`);
    title = app?.title ?? "App";
    body = app ? <AppPage key={app.name} app={app} macs={macs} version={version} {...shared} /> : <p className="settings-muted">{entries ? "This app is not available." : "Loading…"}</p>;
  } else if (route.kind === "server") {
    const known = KNOWN_SERVERS.find((s) => s.id === route.server);
    title = known?.title ?? "MCP server";
    body = known ? <ServerPage key={known.id} known={known} servers={servers} loaded={entries !== null} version={version} {...shared} /> : <p className="settings-muted">This server is not one Axo knows.</p>;
  } else if (route.kind === "servers") {
    title = "MCP servers";
    body = <div className="settings-narrow"><ServersPage servers={servers} loaded={entries !== null} {...shared} /></div>;
  } else if (route.kind === "activity") {
    title = "Activity";
    body = <div className="settings-narrow"><ActivityPage appsUrl={appsUrl} /></div>;
  } else {
    body = <AppsHome apps={apps} servers={servers} loaded={entries !== null} appsUrl={appsUrl} link={link} />;
  }

  return (
    <div className="settings-page" role="region" aria-label={title}>
      <header className="settings-bar">
        <button className="circle-button" onClick={back} aria-label="Back"><Icon name="chevronLeft" size={16} /></button>
        <nav className="settings-crumbs" aria-label="Breadcrumb">
          <span>Settings</span>
          <Icon name="chevronRight" size={12} />
          {route.kind === "apps" ? <span aria-current="page">Apps</span> : <a className="link" {...link({ kind: "apps" })}>Apps</a>}
          {route.kind !== "apps" ? <><Icon name="chevronRight" size={12} /><span aria-current="page">{title}</span></> : null}
        </nav>
        <button className="circle-button" onClick={onClose} aria-label="Close settings"><Icon name="close" size={16} /></button>
      </header>
      <div className="settings-body">
        {notice ? <p className={notice.kind === "ok" ? "apps-notice" : "apps-notice error"} role="status">{notice.text}</p> : null}
        <div className="apps">{body}</div>
      </div>
    </div>
  );
}

const CATEGORY_TITLES: Record<string, string> = {
  communication: "Communication", productivity: "Productivity", files: "Files", developer: "Developer", media: "Media", security: "Security",
  other: "Other", finance: "Finance", social: "Social", travel: "Travel", shopping: "Shopping", entertainment: "Entertainment", health: "Health", home: "Home", marketing: "Marketing",
};
type Status = "all" | "connected" | "notConnected";

/**
 * A settings page link: a real `href`, so ⌘-, Ctrl-, Shift- and middle-click open it as the browser
 * would; a plain click stays in the app.
 */
type Link = (route: SettingsRoute) => { href: string; onClick: (event: MouseEvent<HTMLAnchorElement>) => void };
function linkTo(go: (route: SettingsRoute) => void, hrefOf: (route: SettingsRoute) => string): Link {
  return (route) => ({
    href: hrefOf(route),
    onClick: (event) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      go(route);
    },
  });
}

function AppCardFace({ tile }: { tile: { look: ReactNode; title: string; connected: boolean; detail: string } }) {
  return (
    <>
      {tile.look}
      <strong>{tile.title}</strong>
      <small className={tile.connected ? "connected" : ""}>{tile.connected ? <span className="mac-dot online" aria-hidden="true" /> : null}{tile.detail}</small>
    </>
  );
}


/** Apps: filters, a grid of every app and MCP server, and what Sessions used lately. */
function AppsHome({ apps, servers, loaded, appsUrl, link }: {
  apps: App[]; servers: Server[]; loaded: boolean; appsUrl: string; link: Link;
}) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<Status>("all");
  const [category, setCategory] = useState<string>("all");

  type Tile = { key: string; title: string; subtitle: string; connected: boolean; category: string; provider: string; look: ReactNode; open: SettingsRoute; detail: string };
  const tiles: Tile[] = [
    ...apps.map((app): Tile => ({
      key: app.name, title: app.title, subtitle: app.description, category: app.category || "other", provider: app.provider,
      connected: app.accounts.some((a) => a.state === "ready"), look: <AppTile app={app.name} large />,
      detail: needsClient(app) ? "Needs set-up" : count(app.accounts.length, app.signIn.kind === "mac" ? "Mac" : "account"), open: { kind: "app", app: app.name.slice("apps.".length) },
    })),
    // Every server Axo knows, with how many of it are connected; each opens its own page.
    ...(loaded ? KNOWN_SERVERS : []).map((known): Tile => {
      const added = servers.filter((server) => knownServerOf(server.url)?.id === known.id);
      return {
        key: `mcp:${known.id}`, title: known.title, subtitle: known.description, category: known.category, provider: known.provider,
        connected: added.some((server) => server.state === "ready"), look: <KnownServerTile known={known} large />,
        detail: added.length ? count(added.length, "account") : "Add", open: { kind: "server", server: known.id },
      };
    }),
    // Servers added by URL.
    ...servers.filter((server) => !knownServerOf(server.url)).map((server): Tile => ({
      key: server.name, title: server.title ?? server.name, subtitle: host(server.url), category: "mcp", provider: "MCP",
      connected: server.state === "ready", look: <ServerTile icon={server.icon} large />,
      detail: server.state === "ready" ? count(server.tools, "tool") : server.state === "needsSignIn" ? "Needs sign-in" : "Unreachable",
      open: { kind: "servers" },
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
          {shown.map((tile) => <a key={tile.key} className="app-card" {...link(tile.open)}><AppCardFace tile={tile} /></a>)}
          {loaded && status === "all" && (category === "all" || category === "mcp") && !needle ? (
            <a className="app-card add-card" {...link({ kind: "servers" })}>
              <span className="app-tile large neutral"><Icon name="plug" size={28} /></span>
              <strong>Add MCP server</strong>
              <small>Any server with a URL</small>
            </a>
          ) : null}
          {loaded && shown.length === 0 && needle ? <p className="settings-muted">No app matches “{query}”.</p> : null}
        </div>
      </section>

      <aside className="apps-activity" aria-label="Recent activity">
        <div className="apps-activity-head">
          <h2 className="settings-section">Recent activity</h2>
          <a className="link" {...link({ kind: "activity" })}>See all</a>
        </div>
        <Integrity appsUrl={appsUrl} />
        <Calls appsUrl={appsUrl} limit={12} compact />
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
function Integrity({ appsUrl }: { appsUrl: string }) {
  const [check, setCheck] = useState<{ verified: boolean; events: number; head: string | null; reason: string | null } | null | "failed">(null);
  useEffect(() => {
    let live = true;
    request(`${appsUrl}/log/integrity`, "GET")
      .then((answer) => { if (live) setCheck(answer as { verified: boolean; events: number; head: string | null; reason: string | null }); })
      .catch(() => { if (live) setCheck("failed"); });
    return () => { live = false; };
  }, [appsUrl]);
  if (check === null || check === "failed") return null;
  return (
    <p className={`integrity${check.verified ? "" : " broken"}`} title={check.head ? `Chain head ${check.head}` : undefined}>
      <Icon name={check.verified ? "check" : "warning"} size={14} />
      {check.verified ? `Log intact · ${count(check.events, "entry", "entries")}` : `Log was changed: ${check.reason ?? "unknown"}`}
    </p>
  );
}

type Shared = {
  appsUrl: string;
  busy: boolean;
  act: (work: () => Promise<void>) => Promise<void>;
  setNotice: (notice: Notice) => void;
};

function AppPage({ app, macs, version, appsUrl, busy, act, setNotice }: Shared & { app: App; macs: Mac[]; version: number }) {
  // A token app's Add account is a form on this page; an OAuth app's opens the provider's sign-in.
  const [adding, setAdding] = useState<{ account: string } | null>(null);
  const [device, setDevice] = useState<{ flow: string; shown: Extract<AppDeviceSignIn, { state: "pending" }> } | null>(null);
  // An OAuth app signs in with the person's own client for its provider: set up once, changed any time.
  const [changingClient, setChangingClient] = useState(false);
  const client = app.signIn.kind === "oauth" ? app.signIn.client : undefined;
  // A phone app (Telegram) signs in with the person's own API client: set up once, like an OAuth client.
  const phone = app.signIn.kind === "phone" ? app.signIn : undefined;
  const settingUp = (client !== undefined && (!client.ready || changingClient)) || (phone !== undefined && (!phone.clientReady || changingClient));
  const add = (account = "") => {
    if (app.signIn.kind === "token" || app.signIn.kind === "phone" || app.signIn.kind === "linked") {
      setAdding({ account });
      return;
    }
    if (app.signIn.kind === "device") {
      void act(async () => {
        const { flow, ...answer } = (await request(`${appsUrl}/${encodeURIComponent(app.name)}/device`, "POST")) as { flow: string };
        const shown = appDeviceSignInSchema.parse(answer);
        if (shown.state === "pending") setDevice({ flow, shown });
      });
      return;
    }
    void act(async () => {
      const { signInUrl } = (await request(`${appsUrl}/${encodeURIComponent(app.name)}/sign-in`, "POST")) as { signInUrl: string };
      window.location.assign(signInUrl);
    });
  };
  const revoked = app.signIn.kind === "token"
    ? app.signIn.mac
      ? `Axo deletes a key it created at ${app.provider || "the service"}; one you pasted, delete there too.`
      : `Axo forgets its token. To stop it working, delete it at ${app.provider || "the service"} too.`
    : app.signIn.kind === "device" ? `Axo signs out of ${app.provider || "the provider"}.`
    : app.signIn.kind === "phone" ? `Axo logs its device out of ${app.provider || "the service"}.`
    : app.signIn.kind === "linked" ? `Axo unlinks its device from your ${app.provider || app.title}.`
    : `Axo's access is revoked at ${app.provider || "the provider"}.`;
  const signOut = (account: string) => {
    if (!window.confirm(`Remove ${account} from ${app.title}? Your Sessions can no longer use it. ${revoked}`)) return;
    void act(async () => {
      await request(`${appsUrl}/${encodeURIComponent(app.name)}/remove`, "POST", { account });
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
        {settingUp && client ? (
          <ClientForm app={app} client={client} busy={busy} act={act} appsUrl={appsUrl}
            onDone={() => { setChangingClient(false); setNotice({ kind: "ok", text: `${app.provider || app.title} is set up. Add an account.` }); }}
            onCancel={client.ready ? () => setChangingClient(false) : undefined} />
        ) : null}
        {settingUp && phone ? (
          <PhoneClientForm app={app} signIn={phone} busy={busy} act={act} appsUrl={appsUrl}
            onDone={() => { setChangingClient(false); setNotice({ kind: "ok", text: `${app.provider || app.title} is set up. Add an account.` }); }}
            onCancel={phone.clientReady ? () => setChangingClient(false) : undefined} />
        ) : null}
        {settingUp && !app.accounts.length ? null : <>
        {app.accounts.length || (adding === null && device === null) ? <h2 className="settings-section">Accounts</h2> : null}
        <div className="grouped" hidden={!app.accounts.length && (adding !== null || device !== null)}>
          {app.accounts.map((account) => (
            <div key={account.account} className="grouped-row connection-row">
              <Icon name={app.signIn.kind === "mac" ? "laptop" : "person"} size={18} />
              <span className="connection-copy">
                <strong>{account.account}</strong>
                {account.state === "needsSignIn" ? <small>{app.signIn.kind === "token" ? account.lastError ?? "Needs a new token" : app.signIn.kind === "linked" ? account.lastError ?? "Needs linking again" : "Needs sign-in"}</small> : null}
              </span>
              {account.state === "needsSignIn"
                ? <button className="bordered-button" disabled={busy || device !== null} onClick={() => add(account.account)}>{app.signIn.kind === "token" ? "Add token" : app.signIn.kind === "linked" ? "Link again" : "Sign in"}</button>
                : <span className="mac-dot online" aria-label="Connected" title="Connected" />}
              {app.signIn.kind === "mac" ? null : (
                <button className="plain-icon-button" disabled={busy} onClick={() => signOut(account.account)} aria-label={`Remove ${account.account}`}>
                  <Icon name="close" size={16} />
                </button>
              )}
            </div>
          ))}
          {app.signIn.kind === "mac" && !app.accounts.length ? <p className="grouped-row muted">Pair a Mac to use {app.title}.</p> : null}
          {adding === null && device === null && app.signIn.kind !== "mac" && !settingUp ? <button className="grouped-row add-row" disabled={busy} onClick={() => add()}>{app.signIn.kind === "linked" ? "Link account" : "Add account"}</button> : null}
        </div>
        {client?.ready && !changingClient
          ? <p className="sheet-note">Signs in with your own {app.provider || app.title} OAuth app. <button className="link" type="button" onClick={() => setChangingClient(true)}>Change client</button></p>
          : null}
        {phone?.clientReady && !changingClient && adding === null
          ? <p className="sheet-note">Axo signs in as a new device of yours, with your own {app.provider || app.title} API ID. <button className="link" type="button" onClick={() => setChangingClient(true)}>Change API ID</button></p>
          : null}
        </>}
        {app.signIn.kind === "mac"
          ? <p className="sheet-note">Your Macs are its accounts. {app.signIn.setup} <a href={app.signIn.helpUrl} target="_blank" rel="noreferrer">Learn more</a>.</p>
          : null}
        {device ? <DeviceCode app={app} flow={device.flow} shown={device.shown} appsUrl={appsUrl}
          onDone={(result) => {
            setDevice(null);
            setNotice(result.state === "done" ? { kind: "ok", text: `Added ${result.account}.` } : { kind: "error", text: result.error });
            void act(async () => undefined);
          }} onCancel={() => setDevice(null)} /> : null}
        {adding !== null && app.signIn.kind === "token"
          ? <TokenForm app={app} signIn={app.signIn} macs={macs} account={adding.account} busy={busy} act={act} appsUrl={appsUrl}
            onDone={(account) => { setAdding(null); setNotice({ kind: "ok", text: `Added ${account}.` }); void act(async () => undefined); }}
            onFailed={(error) => setNotice({ kind: "error", text: error })} onCancel={() => setAdding(null)} />
          : null}
        {adding !== null && app.signIn.kind === "linked"
          ? <LinkForm app={app} helpUrl={app.signIn.helpUrl} busy={busy} act={act} appsUrl={appsUrl}
            onDone={(account) => { setAdding(null); setNotice({ kind: "ok", text: `Linked ${account}. Axo is syncing your chats; older ones take a few minutes.` }); void act(async () => undefined); }}
            onFailed={(error) => { setAdding(null); setNotice({ kind: "error", text: error }); }} onCancel={() => setAdding(null)} />
          : null}
        {adding !== null && app.signIn.kind === "phone"
          ? <PhoneSignInForm app={app} busy={busy} act={act} appsUrl={appsUrl}
            onDone={(account) => { setAdding(null); setNotice({ kind: "ok", text: `Added ${account}.` }); void act(async () => undefined); }}
            onFailed={(error) => { setAdding(null); setNotice({ kind: "error", text: error }); }} onCancel={() => setAdding(null)} />
          : null}

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
        <Calls appsUrl={appsUrl} service={app.name} version={version} />
      </aside>
    </div>
  );
}

/**
 * A device sign-in (ChatGPT): the code to enter at the provider, while the page asks Axo every
 * few seconds whether the person has.
 */
function DeviceCode({ app, flow, shown, appsUrl, onDone, onCancel }: {
  app: App; flow: string; shown: Extract<AppDeviceSignIn, { state: "pending" }>; appsUrl: string;
  onDone: (result: Exclude<AppDeviceSignIn, { state: "pending" }>) => void; onCancel: () => void;
}) {
  const [copied, setCopied] = useState(false);
  // The page re-renders while it waits; the poll keeps its own pace.
  const done = useRef(onDone);
  done.current = onDone;
  useEffect(() => {
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const answer = appDeviceSignInSchema.parse(await request(`${appsUrl}/${encodeURIComponent(app.name)}/device/poll`, "POST", { flow }));
        if (!live) return;
        if (answer.state !== "pending") return done.current(answer);
      } catch {
        // A poll that failed is asked again; the code stays valid until it expires.
      }
      if (live) timer = setTimeout(() => void poll(), shown.intervalSeconds * 1000);
    };
    timer = setTimeout(() => void poll(), shown.intervalSeconds * 1000);
    return () => { live = false; clearTimeout(timer); };
  }, [app.name, appsUrl, flow, shown.intervalSeconds]);
  const copy = () => {
    void navigator.clipboard?.writeText(shown.userCode).then(() => setCopied(true), () => undefined);
  };
  return (
    <>
      <h2 className="settings-section">Sign in to {app.title}</h2>
      <div className="grouped device-code">
        <div className="grouped-row device-code-row">
          <span className="connection-copy">
            <strong>Enter this code at {app.provider || app.title}</strong>
            <small>It works for 15 minutes. This page finishes by itself once you have.</small>
          </span>
          <code aria-label="Sign-in code">{shown.userCode}</code>
        </div>
        <div className="grouped-row device-code-actions">
          <button className="link" type="button" onClick={copy}>{copied ? "Copied" : "Copy code"}</button>
          <a className="link" href={shown.verificationUrl} target="_blank" rel="noreferrer">Open {app.provider || app.title}</a>
        </div>
      </div>
      <p className="sheet-note">Only enter it if you started this sign-in here. <button className="link" type="button" onClick={onCancel}>Cancel</button></p>
    </>
  );
}

type TokenSignIn = Extract<App["signIn"], { kind: "token" }>;
/** A paired Mac, which can run a sign-in that ends on localhost (Kraken's). */
type Mac = { name: string; online: boolean };
type OAuthClient = NonNullable<Extract<App["signIn"], { kind: "oauth" }>["client"]>;

/** Whether an OAuth app is waiting for its provider's client to be set up. */
function needsClient(app: App): boolean {
  return app.signIn.kind === "oauth" && app.signIn.client?.ready === false;
}

/**
 * Sets up the OAuth app Axo signs in to a provider with, or replaces it: the person registers it
 * with the provider, with Axo's redirect URI, and enters its ID and secret here once. Axo keeps
 * them encrypted with the account; the secret is never shown again. One serves every app of the
 * provider (all of Google's).
 */
function ClientForm({ app, client, busy, act, appsUrl, onDone, onCancel }: {
  app: App; client: OAuthClient; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: () => void; onCancel?: () => void;
}) {
  const [fields, setFields] = useState({ clientId: "", clientSecret: "" });
  const [copied, setCopied] = useState(false);
  const provider = app.provider || app.title;
  const submit = () => act(async () => {
    await request(`${appsUrl}/${encodeURIComponent(app.name)}/client`, "POST", { clientId: fields.clientId.trim(), clientSecret: fields.clientSecret.trim() });
    setFields({ clientId: "", clientSecret: "" });
    onDone();
  });
  const copy = () => {
    void navigator.clipboard?.writeText(client.redirectUri).then(() => setCopied(true), () => undefined);
  };
  return (
    <>
      <h2 className="settings-section">{onCancel ? `Change ${provider} client` : `Set up ${provider}`}</h2>
      <div className="grouped client-setup">
        <div className="grouped-row client-step">
          <span className="step-number" aria-hidden="true">1</span>
          <span className="connection-copy">
            <strong>Register an OAuth app with {provider}</strong>
            <small>Use this redirect URI. <a className="link" href={client.consoleUrl} target="_blank" rel="noreferrer">Open {provider}</a></small>
          </span>
        </div>
        <div className="grouped-row redirect-row">
          <code aria-label="Redirect URI">{client.redirectUri}</code>
          <button className="link" type="button" onClick={copy}>{copied ? "Copied" : "Copy"}</button>
        </div>
        <div className="grouped-row client-step">
          <span className="step-number" aria-hidden="true">2</span>
          <span className="connection-copy"><strong>Enter its client ID and secret</strong></span>
        </div>
      </div>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        <input className="grouped-row" required placeholder="Client ID" value={fields.clientId} autoComplete="off" autoCapitalize="off" autoCorrect="off" spellCheck={false}
          onChange={(event) => setFields({ ...fields, clientId: event.target.value })} aria-label="Client ID" autoFocus />
        <input className="grouped-row" required type="password" placeholder="Client secret" value={fields.clientSecret} autoComplete="off"
          onChange={(event) => setFields({ ...fields, clientSecret: event.target.value })} aria-label="Client secret" />
        <button className="grouped-row" disabled={busy} type="submit">Save</button>
      </form>
      <p className="sheet-note">
        Axo keeps them encrypted with your account and never shows the secret again.
        {app.provider === "Google" ? " One client serves every Google app." : ""}
        {onCancel ? <> Accounts signed in with the old one may need to sign in again. <button className="link" type="button" onClick={onCancel}>Cancel</button></> : null}
      </p>
    </>
  );
}

/**
 * Links Axo as a device of the person's account (WhatsApp), the way its desktop app is linked: a
 * QR code to scan with the phone, or a pairing code to type into it, for linking from the phone
 * itself. The page asks Axo every two seconds where it stands; the QR code changes as WhatsApp
 * renews it.
 */
function LinkForm({ app, helpUrl, busy, act, appsUrl, onDone, onFailed, onCancel }: {
  app: App; helpUrl: string; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: (account: string) => void; onFailed: (error: string) => void; onCancel: () => void;
}) {
  const [shown, setShown] = useState<Extract<AppLink, { state: "connecting" | "qr" | "code" }> | null>(null);
  const [usingCode, setUsingCode] = useState(false);
  const [phone, setPhone] = useState("");
  const [image, setImage] = useState<string | null>(null);
  const provider = app.provider || app.title;
  const url = `${appsUrl}/${encodeURIComponent(app.name)}/link`;
  const finished = useRef({ onDone, onFailed });
  finished.current = { onDone, onFailed };
  const answered = (answer: AppLink) => {
    if (answer.state === "done") return finished.current.onDone(answer.account);
    if (answer.state === "failed") return finished.current.onFailed(answer.error);
    setShown(answer);
  };
  const start = (body: Record<string, string>) => act(async () => answered(appLinkSchema.parse(await request(url, "POST", body))));
  const flow = shown?.flow ?? null;
  useEffect(() => {
    if (!flow) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const answer = appLinkSchema.parse(await request(url, "POST", { step: "poll", flow }));
        if (!live) return;
        answered(answer);
        if (answer.state === "done" || answer.state === "failed") return;
      } catch {
        // A poll that failed is asked again; the link goes on.
      }
      if (live) timer = setTimeout(() => void poll(), 2000);
    };
    timer = setTimeout(() => void poll(), 2000);
    return () => { live = false; clearTimeout(timer); };
  }, [flow, url]);
  const qr = shown?.state === "qr" ? shown.qr : null;
  useEffect(() => {
    if (!qr) return setImage(null);
    let live = true;
    void QRCode.toDataURL(qr, { margin: 1, width: 264, errorCorrectionLevel: "L" }).then((data) => { if (live) setImage(data); }, () => undefined);
    return () => { live = false; };
  }, [qr]);
  const cancel = () => {
    if (flow) void request(url, "POST", { step: "cancel", flow }).catch(() => undefined);
    onCancel();
  };
  const steps = `On your phone, open ${provider} › Settings › Linked devices › Link a device`;
  return (
    <>
      <h2 className="settings-section">Link {provider}</h2>
      {!shown ? (
        usingCode ? (
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void start({ step: "code", phone: phone.trim() }); }}>
            <p className="grouped-row muted">Your {provider} number, with its country code. You type the code Axo shows into {provider} on that phone.</p>
            <input className="grouped-row" required aria-label="Phone number" placeholder="+44 7700 900123" type="tel" autoComplete="tel"
              value={phone} onChange={(event) => setPhone(event.target.value)} autoFocus />
            <button className="grouped-row" disabled={busy} type="submit">Get a code</button>
          </form>
        ) : (
          <div className="grouped">
            <p className="grouped-row muted">Axo becomes a linked device of yours, like {provider} on a computer. It reads your chats; it never sends messages or marks them read.</p>
            <button className="grouped-row" disabled={busy} onClick={() => void start({ step: "qr" })}>Show a QR code</button>
            <button className="grouped-row" disabled={busy} onClick={() => setUsingCode(true)}>Link with a phone number instead</button>
          </div>
        )
      ) : (
        <div className="grouped device-code">
          {shown.state === "connecting" ? <p className="grouped-row muted">Connecting to {provider}…</p> : null}
          {shown.state === "qr" ? <>
            <p className="grouped-row muted">{steps}, and point the camera at this code. It changes every so often; this page finishes by itself once your phone has linked.</p>
            <div className="grouped-row link-qr-row">
              {image ? <img className="link-qr" src={image} alt={`${provider} linking QR code`} width={264} height={264} /> : null}
            </div>
          </> : null}
          {shown.state === "code" ? <>
            <p className="grouped-row muted">{steps} › Link with phone number instead, and enter this code. This page finishes by itself once your phone has linked.</p>
            <div className="grouped-row device-code-row">
              <span className="connection-copy"><strong>Pairing code</strong></span>
              <code aria-label="Pairing code">{shown.code}</code>
            </div>
          </> : null}
        </div>
      )}
      <p className="sheet-note">
        Axo links through an unofficial {provider} client, and {provider} may restrict accounts it sees using one. <a href={helpUrl} target="_blank" rel="noreferrer">About linked devices</a>. <button className="link" type="button" onClick={cancel}>Cancel</button>
      </p>
    </>
  );
}

type PhoneSignIn = Extract<App["signIn"], { kind: "phone" }>;

/**
 * Sets up a phone app's API client (Telegram's): the person creates one at the service and enters
 * its ID and hash here once. Axo keeps the hash encrypted with the account.
 */
function PhoneClientForm({ app, signIn, busy, act, appsUrl, onDone, onCancel }: {
  app: App; signIn: PhoneSignIn; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: () => void; onCancel?: () => void;
}) {
  const [fields, setFields] = useState({ apiId: "", apiHash: "" });
  const provider = app.provider || app.title;
  const submit = () => act(async () => {
    await request(`${appsUrl}/${encodeURIComponent(app.name)}/client`, "POST", { clientId: fields.apiId.trim(), clientSecret: fields.apiHash.trim() });
    setFields({ apiId: "", apiHash: "" });
    onDone();
  });
  return (
    <>
      <h2 className="settings-section">{onCancel ? `Change ${provider} API ID` : `Set up ${provider}`}</h2>
      <div className="grouped client-setup">
        <div className="grouped-row client-step">
          <span className="step-number" aria-hidden="true">1</span>
          <span className="connection-copy">
            <strong>Create an API ID for yourself</strong>
            <small>{signIn.clientHelp} <a className="link" href={signIn.consoleUrl} target="_blank" rel="noreferrer">Open {provider}</a></small>
          </span>
        </div>
        <div className="grouped-row client-step">
          <span className="step-number" aria-hidden="true">2</span>
          <span className="connection-copy"><strong>Enter its api_id and api_hash</strong></span>
        </div>
      </div>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        <input className="grouped-row" required inputMode="numeric" placeholder="api_id" value={fields.apiId} autoComplete="off" spellCheck={false}
          onChange={(event) => setFields({ ...fields, apiId: event.target.value })} aria-label="api_id" autoFocus />
        <input className="grouped-row" required type="password" placeholder="api_hash" value={fields.apiHash} autoComplete="off"
          onChange={(event) => setFields({ ...fields, apiHash: event.target.value })} aria-label="api_hash" />
        <button className="grouped-row" disabled={busy} type="submit">Save</button>
      </form>
      <p className="sheet-note">
        Axo keeps them encrypted with your account and never shows the hash again.
        {onCancel ? <> Accounts signed in with the old one may need to sign in again. <button className="link" type="button" onClick={onCancel}>Cancel</button></> : null}
      </p>
    </>
  );
}

/**
 * Signs in to a phone app (Telegram) as a new device of the person's: their number, the code the
 * service sends, then their password if the account has one. Axo keeps the service's state between
 * steps; this form only holds the flow.
 */
function PhoneSignInForm({ app, busy, act, appsUrl, onDone, onFailed, onCancel }: {
  app: App; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: (account: string) => void; onFailed: (error: string) => void; onCancel: () => void;
}) {
  const [step, setStep] = useState<Extract<AppPhoneSignIn, { state: "code" | "password" }> | null>(null);
  const [value, setValue] = useState("");
  const provider = app.provider || app.title;
  const send = (body: Record<string, string>) => act(async () => {
    const answer = appPhoneSignInSchema.parse(await request(`${appsUrl}/${encodeURIComponent(app.name)}/phone-sign-in`, "POST", body));
    setValue("");
    if (answer.state === "done") return onDone(answer.account);
    if (answer.state === "failed") return onFailed(answer.error);
    setStep(answer);
  });
  const submit = () => {
    if (!step) return send({ step: "start", phone: value.trim() });
    if (step.state === "code") return send({ step: "code", flow: step.flow, code: value.trim() });
    return send({ step: "password", flow: step.flow, password: value });
  };
  const label = !step ? "Phone number" : step.state === "code" ? "Code" : "Password";
  const hint = !step
    ? `Your ${provider} number, with its country code. ${provider} sends a code to your ${provider} app.`
    : step.state === "code"
      ? step.via === "app" ? `${provider} sent a code to your ${provider} app on another device.` : `${provider} sent a code by SMS.`
      : `Your account has a password (two-step verification).${step.hint ? ` Hint: ${step.hint}.` : ""}`;
  return (
    <>
      <h2 className="settings-section">Sign in to {provider}</h2>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        <p className="grouped-row muted">{step?.error ?? hint}</p>
        <input key={label} className="grouped-row" required aria-label={label} placeholder={!step ? "+44 7700 900123" : label}
          type={step?.state === "password" ? "password" : step ? "text" : "tel"} inputMode={step?.state === "code" ? "numeric" : undefined}
          autoComplete={!step ? "tel" : step.state === "code" ? "one-time-code" : "current-password"} spellCheck={false}
          value={value} onChange={(event) => setValue(event.target.value)} autoFocus />
        <button className="grouped-row" disabled={busy} type="submit">{!step ? "Send code" : "Continue"}</button>
      </form>
      <p className="sheet-note">Axo appears in {provider} › Settings › Devices; ending it there signs Axo out. <button className="link" type="button" onClick={onCancel}>Cancel</button></p>
    </>
  );
}

/** Adds an account to a token app: signed in on a Mac where the app offers it, or pasted. */
function TokenForm({ app, signIn, macs, account, busy, act, appsUrl, onDone, onFailed, onCancel }: {
  app: App; signIn: TokenSignIn; macs: Mac[]; account: string; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: (account: string) => void; onFailed: (error: string) => void; onCancel: () => void;
}) {
  // An app that signs in on a Mac offers that first, and pasting a key beside it.
  const [pasting, setPasting] = useState(!signIn.mac);
  if (signIn.mac && !pasting) {
    return <MacSignInForm app={app} signIn={signIn} offer={signIn.mac} macs={macs} account={account} busy={busy} act={act} appsUrl={appsUrl}
      onDone={onDone} onFailed={onFailed} onPaste={() => setPasting(true)} onCancel={onCancel} />;
  }
  return <PasteForm app={app} signIn={signIn} account={account} busy={busy} act={act} appsUrl={appsUrl} onDone={onDone} onCancel={onCancel} />;
}

/**
 * A token app's sign-in on one of the person's Macs (Kraken's): the Mac opens the service's
 * sign-in page in its browser, and this page waits until Axo has the key.
 */
function MacSignInForm({ app, signIn, offer, macs, account, busy, act, appsUrl, onDone, onFailed, onPaste, onCancel }: {
  app: App; signIn: TokenSignIn; offer: NonNullable<TokenSignIn["mac"]>; macs: Mac[]; account: string; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: (account: string) => void; onFailed: (error: string) => void; onPaste: () => void; onCancel: () => void;
}) {
  const online = macs.filter((m) => m.online);
  const [name, setName] = useState(account);
  const [mac, setMac] = useState(online[0]?.name ?? "");
  const [preset, setPreset] = useState(offer.presets[0].id);
  const [waiting, setWaiting] = useState<{ flow: string; mac: string } | null>(null);
  const provider = app.provider || app.title;
  const done = useRef({ onDone, onFailed });
  done.current = { onDone, onFailed };
  useEffect(() => {
    if (!waiting) return;
    let live = true;
    let timer: ReturnType<typeof setTimeout>;
    const poll = async () => {
      try {
        const answer = appMacSignInSchema.parse(await request(`${appsUrl}/${encodeURIComponent(app.name)}/mac-sign-in/poll`, "POST", { flow: waiting.flow }));
        if (!live) return;
        if (answer.state === "done") return done.current.onDone(answer.account);
        if (answer.state === "failed") {
          setWaiting(null);
          return done.current.onFailed(answer.error);
        }
      } catch {
        // A poll that failed is asked again; the sign-in ends by itself at its timeout.
      }
      if (live) timer = setTimeout(() => void poll(), 2000);
    };
    timer = setTimeout(() => void poll(), 2000);
    return () => { live = false; clearTimeout(timer); };
  }, [app.name, appsUrl, waiting]);
  const submit = () => act(async () => {
    const body = { mac, preset, ...(signIn.named ? { account: name.trim().toLowerCase() } : {}) };
    const { flow } = (await request(`${appsUrl}/${encodeURIComponent(app.name)}/mac-sign-in`, "POST", body)) as { flow: string };
    setWaiting({ flow, mac });
  });
  if (waiting) {
    return (
      <>
        <h2 className="settings-section">Sign in to {provider}</h2>
        <div className="grouped">
          <div className="grouped-row connection-row">
            <Icon name="laptop" size={18} />
            <span className="connection-copy">
              <strong>Finish in the browser on {waiting.mac}</strong>
              <small>{provider}'s sign-in page opened there. This page finishes by itself once you approve.</small>
            </span>
          </div>
        </div>
        <p className="sheet-note">It waits for 5 minutes. <button className="link" type="button" onClick={() => setWaiting(null)}>Stop waiting</button></p>
      </>
    );
  }
  return (
    <>
      <h2 className="settings-section">{account ? `Sign in again as ${account}` : `Add a ${app.title} account`}</h2>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        {signIn.named ? (
          <input className="grouped-row" required minLength={3} maxLength={64} pattern="[A-Za-z0-9][A-Za-z0-9._@\-]*" placeholder="Name, e.g. personal" value={name}
            readOnly={Boolean(account)} autoFocus={!account} onChange={(event) => setName(event.target.value)} aria-label="Account name"
            autoCapitalize="off" autoCorrect="off" spellCheck={false} />
        ) : null}
        <fieldset className="grouped-row preset-choices">
          <legend>What Axo may do</legend>
          {offer.presets.map((p) => (
            <label key={p.id} className="preset-choice">
              <input type="radio" name="preset" value={p.id} checked={preset === p.id} onChange={() => setPreset(p.id)} />
              <span className="connection-copy"><strong>{p.label}</strong><small>{p.description}</small></span>
            </label>
          ))}
        </fieldset>
        <label className="grouped-row mac-choice">
          <span>Sign in on</span>
          <select value={mac} required onChange={(event) => setMac(event.target.value)} aria-label="Mac" disabled={!online.length}>
            {online.length ? online.map((m) => <option key={m.name} value={m.name}>{m.name}</option>) : <option value="">No Mac is online</option>}
          </select>
        </label>
        <button className="grouped-row" disabled={busy || !mac} type="submit">{offer.title}</button>
      </form>
      <p className="sheet-note">
        {provider}'s sign-in page opens in the browser on that Mac. Axo then gets a key with only these permissions, and keeps it encrypted.
        {" "}<button className="link" type="button" onClick={onPaste}>Paste a key instead</button>
        {" · "}<button className="link" type="button" onClick={onCancel}>Cancel</button>
      </p>
    </>
  );
}

/**
 * Adds an account to a token app: what the service issued, pasted once. It is sent to Axo, which
 * checks it with the service and seals it; this page never sees it again.
 */
function PasteForm({ app, signIn, account, busy, act, appsUrl, onDone, onCancel }: {
  app: App; signIn: TokenSignIn; account: string; busy: boolean; appsUrl: string;
  act: Shared["act"]; onDone: (account: string) => void; onCancel: () => void;
}) {
  const [name, setName] = useState(account);
  const [fields, setFields] = useState<Record<string, string>>({});
  const submit = () => act(async () => {
    const body = { ...(signIn.named ? { account: name.trim().toLowerCase() } : {}), fields };
    const added = (await request(`${appsUrl}/${encodeURIComponent(app.name)}/token`, "POST", body)) as { account: string };
    setFields({});
    onDone(added.account);
  });
  return (
    <>
      <h2 className="settings-section">{account ? `New token for ${account}` : `Add a ${app.title} account`}</h2>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void submit(); }}>
        {signIn.named ? (
          <input className="grouped-row" required minLength={3} maxLength={64} pattern="[A-Za-z0-9][A-Za-z0-9._@\-]*" placeholder="Name, e.g. personal" value={name}
            readOnly={Boolean(account)} autoFocus={!account} onChange={(event) => setName(event.target.value)} aria-label="Account name"
            autoCapitalize="off" autoCorrect="off" spellCheck={false} />
        ) : null}
        {signIn.fields.map((field, i) => (
          <input key={field.name} className="grouped-row" required type={field.secret ? "password" : "text"} placeholder={field.label} value={fields[field.name] ?? ""}
            autoFocus={Boolean(account) && i === 0} autoComplete="off" autoCapitalize="off" autoCorrect="off" spellCheck={false}
            onChange={(event) => setFields({ ...fields, [field.name]: event.target.value })} aria-label={field.label} />
        ))}
        <button className="grouped-row" disabled={busy} type="submit">Add</button>
      </form>
      <p className="sheet-note">
        {signIn.fields.map((f) => f.help).join(" ")}{" "}
        <a href={signIn.helpUrl} target="_blank" rel="noreferrer">Open {app.provider || app.title}</a>.
        {" "}Axo checks it with {app.provider || app.title}, keeps it encrypted, and never shows it again.
        {" "}<button className="link" type="button" onClick={onCancel}>Cancel</button>
      </p>
    </>
  );
}

/** Adding a remote MCP server, signing in to it, its client when it registers none itself, and removing it. */
function useServers({ appsUrl, act, setNotice }: Shared) {
  const [clientFor, setClientFor] = useState<string | null>(null);
  const [client, setClient] = useState({ clientId: "", clientSecret: "" });
  const nameOf = (server: Pick<Server, "name" | "title">) => server.title ?? server.name;

  const add = (draft: { name: string; url: string }, then: () => void) => act(async () => {
    const result = appsResults["axo.apps.add"].parse(await request(appsUrl, "POST", { name: draft.name.trim(), url: draft.url }));
    then();
    if (result.signInUrl?.includes("/oauth/start")) window.location.assign(result.signInUrl);
    else if (result.app.kind === "thirdParty" && result.app.state === "needsSignIn") setClientFor(result.app.name);
    else if (result.app.kind === "thirdParty") setNotice({ kind: "ok", text: `Added ${nameOf(result.app)}.` });
  });
  const signIn = (name: string) => act(async () => {
    const { signInUrl } = (await request(`${appsUrl}/${encodeURIComponent(name)}/sign-in`, "POST")) as { signInUrl: string };
    if (signInUrl.includes("/oauth/start")) window.location.assign(signInUrl);
    else setClientFor(name);
  });
  const saveClient = (name: string) => act(async () => {
    const body = { clientId: client.clientId.trim(), clientSecret: client.clientSecret.trim() || null };
    const { signInUrl } = (await request(`${appsUrl}/${encodeURIComponent(name)}/client`, "POST", body)) as { signInUrl: string };
    setClient({ clientId: "", clientSecret: "" });
    setClientFor(null);
    if (signInUrl.includes("/oauth/start")) window.location.assign(signInUrl);
  });
  const remove = (server: Server) => {
    if (!window.confirm(`Remove ${nameOf(server)}? Your Sessions can no longer use it.`)) return;
    void act(async () => {
      await request(`${appsUrl}/${encodeURIComponent(server.name)}/remove`, "POST");
      setNotice({ kind: "ok", text: `Removed ${nameOf(server)}.` });
    });
  };
  return { add, signIn, saveClient, remove, clientFor, client, setClient, nameOf };
}
type ServerActions = ReturnType<typeof useServers>;

/** One added server: what the person called it, how scripts reach it, and its state. */
function ServerRow({ server, look, busy, actions }: { server: Server; look: ReactNode; busy: boolean; actions: ServerActions }) {
  const state = server.state === "needsSignIn" ? "needs sign-in" : server.state === "error" ? "unreachable" : server.lastError ? server.lastError : "";
  return (
    <div className="grouped-row connection-row">
      {look}
      <span className="connection-copy">
        <strong>{actions.nameOf(server)}</strong>
        <small>{[`codemode.${server.name}`, state].filter(Boolean).join(" · ")}</small>
      </span>
      {server.state === "needsSignIn"
        ? <button className="bordered-button" disabled={busy} onClick={() => void actions.signIn(server.name)}>Sign in</button>
        : <span className={`mac-dot ${server.state === "ready" ? "online" : ""}`} aria-label={server.state === "ready" ? "Connected" : "Error"} />}
      <button className="plain-icon-button" disabled={busy} onClick={() => actions.remove(server)} aria-label={`Remove ${actions.nameOf(server)}`}><Icon name="close" size={16} /></button>
    </div>
  );
}

/** The client form, for a server that does not register Axo as a client by itself. */
function ServerClient({ name, busy, actions, consoleUrl }: { name: string; busy: boolean; actions: ServerActions; consoleUrl?: string }) {
  return (
    <>
      <h2 className="settings-section">Sign in to {name}</h2>
      <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void actions.saveClient(name); }}>
        <input className="grouped-row" required placeholder="Client ID" value={actions.client.clientId} autoComplete="off"
          onChange={(event) => actions.setClient({ ...actions.client, clientId: event.target.value })} aria-label="Client ID" />
        <input className="grouped-row" type="password" placeholder="Client secret, if there is one" value={actions.client.clientSecret} autoComplete="off"
          onChange={(event) => actions.setClient({ ...actions.client, clientSecret: event.target.value })} aria-label="Client secret" />
        <button className="grouped-row" disabled={busy} type="submit">Save and sign in</button>
      </form>
      <p className="sheet-note">
        This server needs an OAuth app you create{consoleUrl ? <> at <a href={consoleUrl} target="_blank" rel="noreferrer">{host(consoleUrl)}</a></> : " with its provider"}, with redirect URI https://axo.leostera.dev/api/v1/connections/oauth/callback.
      </p>
    </>
  );
}

/** A server Axo knows: what it is, each of it the person added under a name of theirs, and adding another. */
function ServerPage({ known, servers, loaded, version, ...shared }: Shared & { known: KnownServer; servers: Server[]; loaded: boolean; version: number }) {
  const { busy, appsUrl } = shared;
  const actions = useServers(shared);
  const added = servers.filter((server) => knownServerOf(server.url)?.id === known.id);
  const [adding, setAdding] = useState<string | null>(null);
  const startAdding = () => setAdding(added.length ? "" : known.title);
  return (
    <div className="app-layout">
      <aside className="app-info">
        <KnownServerTile known={known} large />
        <h1>{known.title}</h1>
        <p className="app-meta">{[known.provider, "MCP server", CATEGORY_TITLES[known.category] ?? known.category].join(" · ")}</p>
        <p>{known.description}</p>
        <p className="app-meta">{host(known.url)}</p>
      </aside>

      <section className="app-main">
        <h2 className="settings-section">Accounts</h2>
        <div className="grouped">
          {!loaded ? <p className="grouped-row muted">Loading…</p> : null}
          {added.map((server) => <ServerRow key={server.name} server={server} look={<KnownServerTile known={known} />} busy={busy} actions={actions} />)}
          {adding === null ? <button className="grouped-row add-row" disabled={busy} onClick={startAdding}>{known.signIn === "none" ? "Add" : "Add account"}</button> : null}
        </div>
        {adding !== null ? (
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void actions.add({ name: adding, url: known.url }, () => setAdding(null)); }}>
            <input className="grouped-row" required maxLength={100} placeholder={`Name, e.g. ${known.title}: work`} value={adding} autoFocus
              onChange={(event) => setAdding(event.target.value)} aria-label="Name" autoCorrect="off" spellCheck={false} />
            <button className="grouped-row" disabled={busy} type="submit">{known.signIn === "none" ? "Add" : "Add and sign in"}</button>
          </form>
        ) : null}
        <p className="sheet-note">
          {known.signIn === "none" ? "Needs no sign-in." : "Add it once for each account you have with it, each under its own name."}{" "}
          Sessions reach each one by its name, as <code>codemode.{added[0]?.name ?? "name"}.*</code>.
        </p>
        {actions.clientFor && added.some((server) => server.name === actions.clientFor)
          ? <ServerClient name={actions.clientFor} busy={busy} actions={actions} consoleUrl={known.consoleUrl} /> : null}
      </section>

      <aside className="app-activity">
        <h2 className="settings-section">Recent activity</h2>
        {added.length ? added.map((server) => (
          <div key={server.name}>
            {added.length > 1 ? <h3 className="settings-subsection">{actions.nameOf(server)}</h3> : null}
            <Calls appsUrl={appsUrl} service={server.name} version={version} limit={added.length > 1 ? 5 : undefined} />
          </div>
        )) : <p className="settings-muted">Nothing yet.</p>}
      </aside>
    </div>
  );
}

function ServersPage({ servers, loaded, ...shared }: Shared & { servers: Server[]; loaded: boolean }) {
  const { busy } = shared;
  const actions = useServers(shared);
  const [adding, setAdding] = useState<{ name: string; url: string } | null>(null);
  const look = (server: Server) => {
    const known = knownServerOf(server.url);
    return known ? <KnownServerTile known={known} /> : <ServerTile icon={server.icon} />;
  };
  return (
    <>
      <header className="settings-hero">
        <h1>MCP servers</h1>
        <p>Add any MCP server, and your Sessions can use its tools.</p>
      </header>
      <div className="grouped">
        {!loaded ? <p className="grouped-row muted">Loading…</p> : null}
        {servers.map((server) => <ServerRow key={server.name} server={server} look={look(server)} busy={busy} actions={actions} />)}
        {adding === null ? <button className="grouped-row add-row" disabled={busy} onClick={() => setAdding({ name: "", url: "" })}>Add server</button> : null}
      </div>

      {adding !== null ? (
        <>
          <h2 className="settings-section">Add server</h2>
          <form className="grouped connection-form" onSubmit={(event) => { event.preventDefault(); void actions.add(adding, () => setAdding(null)); }}>
            <input className="grouped-row" required maxLength={100} placeholder="Name, e.g. emdash: leostera.com" value={adding.name} autoFocus
              onChange={(event) => setAdding({ ...adding, name: event.target.value })} aria-label="Name" autoCorrect="off" spellCheck={false} />
            <input className="grouped-row" required type="url" pattern="https://.*" placeholder="https://mcp.example.com/mcp" value={adding.url}
              onChange={(event) => setAdding({ ...adding, url: event.target.value })} aria-label="Server URL" />
            <button className="grouped-row" disabled={busy} type="submit">Add</button>
          </form>
        </>
      ) : null}

      {actions.clientFor ? <ServerClient name={actions.clientFor} busy={busy} actions={actions} /> : null}
    </>
  );
}

function ActivityPage({ appsUrl }: { appsUrl: string }) {
  return (
    <>
      <header className="settings-hero">
        <h1>Activity</h1>
        <p>What your Sessions used in the last 30 days.</p>
      </header>
      <Integrity appsUrl={appsUrl} />
      <Calls appsUrl={appsUrl} />
    </>
  );
}

/** Recent calls, of every app and server or of one. */
function Calls({ appsUrl, service, version = 0, limit, compact = false }: { appsUrl: string; service?: string; version?: number; limit?: number; compact?: boolean }) {
  const [records, setRecords] = useState<CallRecord[] | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let live = true;
    const query = new URLSearchParams({ limit: String(limit ?? (service ? 20 : 50)), ...(service ? { service } : {}) });
    request(`${appsUrl}/log?${query}`, "GET")
      .then((log) => { if (live) setRecords(appsResults["axo.apps.log"].parse(log).records); })
      .catch(() => { if (live) setFailed(true); });
    return () => { live = false; };
  }, [appsUrl, service, version, limit]);
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

/** Each app's own logo, as its maker draws it, bundled with the page. */
const APP_LOGOS: Record<string, string> = {
  "apps.gmail": gmailLogo,
  "apps.calendar": calendarLogo,
  "apps.drive": driveLogo,
  "apps.docs": docsLogo,
  "apps.sheets": sheetsLogo,
  "apps.slides": slidesLogo,
  "apps.contacts": contactsLogo,
  "apps.tasks": tasksLogo,
  "apps.meet": meetLogo,
  "apps.cloud": cloudLogo,
  "apps.hetzner": hetznerLogo,
  "apps.chatgpt": chatgptLogo,
  "apps.onepassword": onepasswordLogo,
  "apps.octopus": octopusLogo,
  "apps.wise": wiseLogo,
  "apps.telegram": telegramLogo,
  "apps.kraken": krakenLogo,
  "apps.github": githubLogo,
  "apps.discord": discordLogo,
  "apps.unifi": unifiLogo,
  "apps.spotify": spotifyLogo,
  "apps.withings": withingsLogo,
  "apps.whatsapp": whatsappLogo,
};
/** Logos drawn as a full tile of their own, not a mark on white. */
const FULL_LOGOS = new Set(["apps.hetzner", "apps.wise", "apps.kraken", "apps.unifi"]);

function AppTile({ app, large = false }: { app: string; large?: boolean }) {
  const logo = APP_LOGOS[app];
  if (!logo) return <span className={`app-tile neutral${large ? " large" : ""}`} aria-hidden="true"><Icon name="plug" size={large ? 28 : 18} /></span>;
  return <span className={`app-tile logo${FULL_LOGOS.has(app) ? " full" : ""}${large ? " large" : ""}`} aria-hidden="true"><img src={logo} alt="" draggable={false} /></span>;
}

/** A known server's tile: its maker's logo, bundled. */
function KnownServerTile({ known, large = false }: { known: KnownServer; large?: boolean }) {
  return <span className={`app-tile logo${known.full ? " full" : ""}${large ? " large" : ""}`} aria-hidden="true"><img src={known.logo} alt="" draggable={false} /></span>;
}

/** An MCP server's tile: the icon the Worker found for it, or a plug when it has none or it does not load. */
function ServerTile({ icon, large = false }: { icon: string | null; large?: boolean }) {
  const [failed, setFailed] = useState(false);
  if (!icon || failed) return <span className={`app-tile neutral${large ? " large" : ""}`} aria-hidden="true"><Icon name="plug" size={large ? 28 : 18} /></span>;
  return (
    <span className={`app-tile logo site${large ? " large" : ""}`} aria-hidden="true">
      <img src={icon} alt="" draggable={false} referrerPolicy="no-referrer" onError={() => setFailed(true)} />
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
  bash: "Terminal", computer: "Computer use", hosts: "Macs",
  "apps.gmail": "Gmail", "apps.calendar": "Calendar", "apps.drive": "Drive", "apps.docs": "Docs", "apps.sheets": "Sheets",
  "apps.slides": "Slides", "apps.contacts": "Contacts", "apps.tasks": "Tasks", "apps.meet": "Meet", "apps.cloud": "Google Cloud", "apps.hetzner": "Hetzner", "apps.chatgpt": "ChatGPT", "apps.onepassword": "1Password", "apps.octopus": "Octopus Energy", "apps.wise": "Wise", "apps.telegram": "Telegram", "apps.kraken": "Kraken", "apps.github": "GitHub", "apps.discord": "Discord", "apps.unifi": "UniFi", "apps.spotify": "Spotify", "apps.withings": "Withings",
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
