import {
  AxoApiError,
  AxoRpcError,
  RemoteAxoApi,
  type Host,
  type HostEvent,
  type HostRef,
  type HostRelayConnection,
  type Session,
} from "@axo/app";
import type { Layout } from "@axo/protocol/v1";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, type ComponentProps, type CSSProperties } from "react";
import type { TerminalRegistry } from "./terminal-pane";

const TerminalPane = lazy(async () => {
  const module = await import("./terminal-pane");
  return { default: module.TerminalPane };
});

const DEFAULT_API_URL = "https://axo.leostera.dev";
const apiBaseUrl = import.meta.env.VITE_AXO_API_BASE_URL || DEFAULT_API_URL;

type ConnectionState = "disconnected" | "connecting" | "live" | "error";
type Activity = "running" | "exited" | "attached" | "detached" | "unknown";

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function terminalKey(sessionId: number, shellId: number): string {
  return `${sessionId}:${shellId}`;
}

function messageFor(error: unknown): string {
  if (error instanceof AxoApiError && (error.status === 401 || error.status === 403)) {
    return "Your Axo sign-in expired. Sign in again to reconnect to your hosts.";
  }
  if (error instanceof AxoRpcError) {
    return `The host rejected the request (${error.code}): ${error.message}`;
  }
  if (error instanceof Error) return error.message;
  return "The Axo API request failed.";
}

function sessionsWithUpdate(sessions: Session[], updated: Session): Session[] {
  return [...sessions.filter(({ sessionId }) => sessionId !== updated.sessionId), updated]
    .sort((left, right) => left.sessionId - right.sessionId);
}

function TerminalPaneSlot(props: ComponentProps<typeof TerminalPane>) {
  return (
    <Suspense fallback={<div className="terminal-loading">Opening terminal pane…</div>}>
      <TerminalPane {...props} />
    </Suspense>
  );
}

function LayoutBranch({

  layout,
  session,
  hostGeneration,
  connection,
  active,
  registry,
  activities,
  focusedShellId,
  setFocusedShellId,
  onInputError,
}: {
  layout: Layout;
  session: Session;
  hostGeneration: string;
  connection: HostRelayConnection | null;
  active: boolean;
  registry: TerminalRegistry;
  activities: Record<number, Activity>;
  focusedShellId: number | null;
  setFocusedShellId: (shellId: number) => void;
  onInputError: (error: unknown) => void;
}) {
  if (layout.kind === "pane") {
    if (!session.shells.some((shell) => shell.shellId === layout.shellId)) return null;
    return (
      <TerminalPaneSlot
        key={layout.shellId}
        session={session}
        shellId={layout.shellId}
        hostGeneration={hostGeneration}
        connection={connection}
        active={active}
        registry={registry}
        activity={activities[layout.shellId] ?? "unknown"}
        focused={focusedShellId === layout.shellId}
        onFocus={() => setFocusedShellId(layout.shellId)}
        onInputError={onInputError}
      />
    );
  }

  return (
    <div className={`layout-split layout-split-${layout.direction}`}>
      <div className="layout-child" style={{ flexBasis: `${layout.ratio * 100}%` }}>
        <LayoutBranch {...{
          layout: layout.first,
          session,
          hostGeneration,
          connection,
          active,
          registry,
          activities,
          focusedShellId,
          setFocusedShellId,
          onInputError,
        }} />
      </div>
      <div className="layout-divider" aria-hidden="true" />
      <div className="layout-child" style={{ flexBasis: `${(1 - layout.ratio) * 100}%` }}>
        <LayoutBranch {...{
          layout: layout.second,
          session,
          hostGeneration,
          connection,
          active,
          registry,
          activities,
          focusedShellId,
          setFocusedShellId,
          onInputError,
        }} />
      </div>
    </div>
  );
}

type AccountProfile = { email: string | null; name: string | null };

type RemoteTerminalAppProps = {
  profile?: AccountProfile;
  accountError?: string | null;
  pairingCode?: string | null;
  pairingExpiresAt?: string | null;
  creatingPairing?: boolean;
  onCreatePairing?: () => void;
  onCopyPairingCode?: () => void;
  onDismissPairing?: () => void;
  onSignOut?: () => void;
};

export function RemoteTerminalApp({
  profile,
  accountError = null,
  pairingCode = null,
  pairingExpiresAt = null,
  creatingPairing = false,
  onCreatePairing,
  onCopyPairingCode,
  onDismissPairing,
  onSignOut,
}: RemoteTerminalAppProps = {}) {
  const api = useMemo(() => new RemoteAxoApi(apiBaseUrl), []);
  const registry = useRef<TerminalRegistry>(new Map());
  const connectionRef = useRef<Awaited<ReturnType<RemoteAxoApi["connectHost"]>> | null>(null);
  const [hosts, setHosts] = useState<Host[]>([]);
  const [selectedHostId, setSelectedHostId] = useState<string | null>(null);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [selectedSessionId, setSelectedSessionId] = useState<number | null>(null);
  const [activities, setActivities] = useState<Record<number, Activity>>({});
  const [focusedShellId, setFocusedShellId] = useState<number | null>(null);
  const [connectionState, setConnectionState] = useState<ConnectionState>("disconnected");
  const [error, setError] = useState<string | null>(null);
  const [loadingHosts, setLoadingHosts] = useState(true);
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [newSessionBusy, setNewSessionBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  const selectedHost = hosts.find((host) => host.hostId === selectedHostId) ?? null;
  const selectedSession = sessions.find((session) => session.sessionId === selectedSessionId) ?? null;
  const active = Boolean(selectedHost && selectedHost.status === "online" && connectionState === "live");
  const apiLoginUrl = new URL("/app", apiBaseUrl).href;

  const refreshHosts = useCallback(async (signal?: AbortSignal) => {
    try {
      const currentHosts = await api.listHosts(signal);
      setHosts(currentHosts);
      setSelectedHostId((current) => {
        if (current && currentHosts.some((host) => host.hostId === current)) return current;
        return currentHosts[0]?.hostId ?? null;
      });
      setError(null);
    } catch (requestError) {
      if (!signal?.aborted) setError(messageFor(requestError));
    } finally {
      if (!signal?.aborted) setLoadingHosts(false);
    }
  }, [api]);

  useEffect(() => {
    const controller = new AbortController();
    void refreshHosts(controller.signal);
    const timer = window.setInterval(() => void refreshHosts(), 30_000);
    return () => {
      controller.abort();
      window.clearInterval(timer);
    };
  }, [refreshHosts]);

  useEffect(() => {
    if (!selectedHost) {
      setSessions([]);
      setSelectedSessionId(null);
      setLoadingSessions(false);
      return;
    }

    const reference: HostRef = {
      hostId: selectedHost.hostId,
      hostGeneration: selectedHost.hostGeneration,
    };
    const controller = new AbortController();
    setSessions(selectedHost.sessions);
    setSelectedSessionId((current) =>
      current !== null && selectedHost.sessions.some((session) => session.sessionId === current)
        ? current
        : selectedHost.sessions[0]?.sessionId ?? null,
    );
    setLoadingSessions(true);
    void api.listHostSessions(reference, controller.signal).then((latest) => {
      setSessions(latest);
      setSelectedSessionId((current) =>
        current !== null && latest.some((session) => session.sessionId === current)
          ? current
          : latest[0]?.sessionId ?? null,
      );
      setError(null);
    }).catch((requestError) => {
      if (!controller.signal.aborted) setError(messageFor(requestError));
    }).finally(() => {
      if (!controller.signal.aborted) setLoadingSessions(false);
    });
    return () => controller.abort();
  }, [api, selectedHost?.hostId, selectedHost?.hostGeneration]);

  const applyEvent = useCallback((event: HostEvent) => {
    if (event.type === "host.presence") {
      setHosts((current) => current.map((host) => host.hostId === event.hostId
        ? { ...host, hostGeneration: event.hostGeneration, status: event.status, stale: event.status === "offline", lastSeenAt: event.observedAt }
        : host));
      setConnectionState(event.status === "online" ? "live" : "disconnected");
      return;
    }

    const data = event.event;
    if (data.type === "session.snapshot") {
      setHosts((current) => current.map((host) => host.hostId === event.hostId
        ? { ...host, sessions: sessionsWithUpdate(host.sessions, data.snapshot) }
        : host));
      setSessions((current) => sessionsWithUpdate(current, data.snapshot));
      setSelectedSessionId((current) => current ?? data.snapshot.sessionId);
      setNotice(`Session ${data.snapshot.sessionId} updated`);
      return;
    }
    if (data.type === "session.removed") {
      setHosts((current) => current.map((host) => host.hostId === event.hostId
        ? { ...host, sessions: host.sessions.filter((session) => session.sessionId !== data.sessionId) }
        : host));
      setSessions((current) => current.filter((session) => session.sessionId !== data.sessionId));
      setSelectedSessionId((current) => current === data.sessionId ? null : current);
      return;
    }
    if (data.type === "shell.activity") {
      const nextActivity: Activity = data.activity === "started" ? "running" : data.activity;
      setActivities((current) => ({ ...current, [data.shellId]: nextActivity }));
      return;
    }
    if (data.type === "terminal.output") {
      registry.current.get(terminalKey(data.sessionId, data.shellId))?.write(decodeBase64(data.data));
    }
  }, []);

  useEffect(() => {
    connectionRef.current?.close();
    connectionRef.current = null;
    setConnectionState("disconnected");
    setActivities({});
    if (!selectedHost || selectedHost.status !== "online") return;

    let cancelled = false;
    const reference: HostRef = {
      hostId: selectedHost.hostId,
      hostGeneration: selectedHost.hostGeneration,
    };
    setConnectionState("connecting");
    setError(null);
    let candidate: HostRelayConnection | null = null;
    const onConnectionClosed = (connectionError: Error) => {
      if (cancelled || (candidate && connectionRef.current !== candidate)) return;
      connectionRef.current = null;
      setConnectionState("error");
      setError(messageFor(connectionError));
    };
    void api.connectHost(reference, applyEvent, onConnectionClosed).then((connection) => {
      candidate = connection;
      if (cancelled) {
        connection.close();
        return;
      }
      if (!connection.active) {
        setConnectionState("error");
        setError("Axo API relay closed while connecting");
        return;
      }
      connectionRef.current = connection;
      setConnectionState("live");
    }).catch((connectionError) => {
      if (cancelled) return;
      setConnectionState("error");
      setError(messageFor(connectionError));
    });

    return () => {
      cancelled = true;
      connectionRef.current?.close();
      connectionRef.current = null;
    };
  }, [api, applyEvent, selectedHost?.hostId, selectedHost?.hostGeneration, selectedHost?.status]);

  const openNewSession = useCallback(async () => {
    if (!selectedHost || !connectionRef.current?.active || newSessionBusy) return;
    setNewSessionBusy(true);
    setError(null);
    try {
      const created = await connectionRef.current.call("axo.remote.session.create", {
        target: {
          hostId: selectedHost.hostId,
          hostGeneration: selectedHost.hostGeneration,
        },
      });
      const newSession = created.session;
      setSessions((current) => sessionsWithUpdate(current, newSession));
      setHosts((current) => current.map((host) => host.hostId === selectedHost.hostId
        ? { ...host, sessions: sessionsWithUpdate(host.sessions, newSession) }
        : host));
      setSelectedSessionId(newSession.sessionId);
      setFocusedShellId(newSession.shells[0]?.shellId ?? null);
      setNotice(`Session ${newSession.sessionId} opened`);
    } catch (requestError) {
      setError(messageFor(requestError));
    } finally {
      setNewSessionBusy(false);
    }
  }, [newSessionBusy, selectedHost]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!(event.metaKey && event.key.toLowerCase() === "t") || event.repeat) return;
      event.preventDefault();
      void openNewSession();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [openNewSession]);

  const reportInputError = useCallback((inputError: unknown) => {
    setError(messageFor(inputError));
  }, []);

  const selectHost = useCallback((hostId: string) => {
    setSelectedHostId(hostId);
    setSelectedSessionId(null);
    setFocusedShellId(null);
    setError(null);
    setNotice(null);
  }, []);

  const selectSession = useCallback((sessionId: number) => {
    setSelectedSessionId(sessionId);
    setFocusedShellId(null);
    setError(null);
    setNotice(null);
  }, []);

  const branch = useMemo(() => {
    if (!selectedSession?.layout) return null;
    const paneIds = new Set<number>();
    const inspect = (layout: Layout) => {
      if (layout.kind === "pane") paneIds.add(layout.shellId);
      else {
        inspect(layout.first);
        inspect(layout.second);
      }
    };
    inspect(selectedSession.layout);
    const allShellsHavePane = selectedSession.shells.every(({ shellId }) => paneIds.has(shellId));
    return allShellsHavePane ? selectedSession.layout : null;
  }, [selectedSession]);

  return (
    <main className="remote-app">
      <aside className="sidebar">
        <div className="sidebar-heading sidebar-hosts-heading">
          <span>Hosts</span>
          <button className="icon-button refresh-button" onClick={() => void refreshHosts()} title="Refresh hosts" aria-label="Refresh hosts">
            ↻
          </button>
        </div>
        <div className="host-list" aria-label="Hosts">
          {loadingHosts && hosts.length === 0 ? <p className="sidebar-empty">Finding your hosts…</p> : null}
          {!loadingHosts && hosts.length === 0 ? <p className="sidebar-empty">No Axo hosts are registered yet.</p> : null}
          {hosts.map((host) => (
            <button
              className={`host-card ${selectedHostId === host.hostId ? "selected" : ""}`}
              key={host.hostId}
              onClick={() => selectHost(host.hostId)}
            >
              <span className={`status-dot ${host.status}`} />
              <span className="host-copy">
                <span className="host-label">{host.label}</span>
                <span className="host-kind">{host.hostKind} · {host.status === "online" ? "online" : "offline"}</span>
              </span>
              <span className="host-chevron">›</span>
            </button>
          ))}
        </div>

        {selectedHost ? (
          <>
            <div className="sidebar-heading sessions-heading">
              <span>Sessions</span>
              <span className="count-pill">{sessions.length}</span>
            </div>
            <div className="session-list" aria-label="Sessions">
              {loadingSessions && sessions.length === 0 ? <p className="sidebar-empty">Loading sessions…</p> : null}
              {sessions.map((session) => (
                <button
                  className={`session-card ${selectedSessionId === session.sessionId ? "selected" : ""}`}
                  key={session.sessionId}
                  onClick={() => selectSession(session.sessionId)}
                >
                  <span className="session-icon" aria-hidden="true">&gt;_</span>
                  <span className="session-copy">
                    <span className="session-name">Session {session.sessionId}</span>
                    <span className="session-meta">{session.shells.length} {session.shells.length === 1 ? "pane" : "panes"}</span>
                  </span>
                </button>
              ))}
              {!loadingSessions && sessions.length === 0 ? <p className="sidebar-empty">This host has no sessions.</p> : null}
            </div>
          </>
        ) : null}

        <div className="sidebar-bottom">
          <span className="access-lock">◈</span>
          <span>Private to your Axo account</span>
        </div>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div className="breadcrumbs">
            <span className="breadcrumb-muted">{selectedHost?.label ?? "Your workspace"}</span>
            {selectedSession ? <><span className="breadcrumb-separator">/</span><h1 className="breadcrumb-session">Session {selectedSession.sessionId}</h1></> : null}
          </div>
          <div className="topbar-actions">
            <span className={`connection-chip ${connectionState}`}>
              <span className="status-dot" />
              {connectionState === "live" ? "Live" : connectionState === "connecting" ? "Connecting" : connectionState === "error" ? "Unavailable" : "Offline"}
            </span>
            {onCreatePairing ? (
              <button className="link-host-button" onClick={onCreatePairing} disabled={creatingPairing}>
                {creatingPairing ? "Creating code…" : "Link a Mac"}
              </button>
            ) : null}
            <button className="new-session-button" onClick={() => void openNewSession()} disabled={!active || newSessionBusy} title="New session (⌘T)">
              <span className="plus">＋</span> New session <kbd>⌘T</kbd>
            </button>
            {onSignOut ? (
              <div className="account-actions">
                <span title={profile?.email ?? undefined}>{profile?.name || profile?.email || "Axo account"}</span>
                <button className="account-signout" onClick={onSignOut}>Sign out</button>
              </div>
            ) : null}
          </div>
        </header>

        {error ? (
          <div className="message-banner error-banner" role="alert">
            <span>{error}</span>
            {(error.includes("sign-in expired") || error.includes("reach the Axo API")) ? (
              <a href={apiLoginUrl} target="_blank" rel="noreferrer">Sign in to Axo ↗</a>
            ) : null}
            <button onClick={() => setError(null)} aria-label="Dismiss error">×</button>
          </div>
        ) : null}
        {notice ? (
          <div className="message-banner notice-banner" role="status">
            <span>{notice}</span><button onClick={() => setNotice(null)} aria-label="Dismiss notice">×</button>
          </div>
        ) : null}
        {accountError ? (
          <div className="message-banner error-banner" role="alert"><span>{accountError}</span></div>
        ) : null}

        {!selectedHost ? (
          <div className="welcome-state">
            <div className="welcome-orbit"><span>⌘</span></div>
            <p className="eyebrow">YOUR MACHINES, IN REACH</p>
            <h1>Terminals that<br /><span>come with you.</span></h1>
            <p className="welcome-copy">Connect an Axo host to see its sessions here. Your terminal stays on your Mac; only session metadata and live output travel through Axo.</p>
            {error ? <button className="retry-button" onClick={() => void refreshHosts()}>Try again</button> : null}
          </div>
        ) : (
          <div className="terminal-workspace">
            {selectedHost.status === "offline" ? (
              <div className="offline-callout">
                <div className="offline-icon">◌</div>
                <div><strong>Host is offline</strong><p>Showing the last session and pane metadata received from this Mac. Live terminal output is only sent while the host is connected.</p></div>
              </div>
            ) : null}

            {selectedSession ? (
              <div className="terminal-frame">
                <div className="terminal-canvas">
                  {branch ? (
                    <LayoutBranch
                      layout={branch}
                      session={selectedSession}
                      hostGeneration={selectedHost.hostGeneration}
                      connection={connectionRef.current}
                      active={active}
                      registry={registry.current}
                      activities={activities}
                      focusedShellId={focusedShellId}
                      setFocusedShellId={setFocusedShellId}
                      onInputError={reportInputError}
                    />
                  ) : selectedSession.shells.length > 0 ? (
                    <div className="layout-grid" style={{ "--pane-count": selectedSession.shells.length } as CSSProperties}>
                      {selectedSession.shells.map(({ shellId }) => (
                        <TerminalPaneSlot
                          key={shellId}
                          session={selectedSession}
                          shellId={shellId}
                          hostGeneration={selectedHost.hostGeneration}
                          connection={connectionRef.current}
                          active={active}
                          registry={registry.current}
                          activity={activities[shellId] ?? "unknown"}
                          focused={focusedShellId === shellId}
                          onFocus={() => setFocusedShellId(shellId)}
                          onInputError={reportInputError}
                        />
                      ))}
                    </div>
                  ) : (
                    <div className="empty-terminal"><span>⌘</span><strong>No panes in this session</strong><p>Create a new session to open a terminal pane.</p></div>
                  )}
                </div>
              </div>
            ) : (
              <div className="empty-session">
                <div className="empty-session-icon">＋</div>
                <h2>{sessions.length ? "Choose a session" : "Nothing running yet"}</h2>
                <p>{sessions.length ? "Select a session from the sidebar to view its panes." : "Open a session on this host to start a remote terminal."}</p>
                {selectedHost.status === "online" ? <button className="new-session-button large" onClick={() => void openNewSession()} disabled={!active || newSessionBusy}>＋ Open a session <kbd>⌘T</kbd></button> : null}
              </div>
            )}
            <footer className="workspace-footer">
              <span>Terminal data is live-only. Axo stores host and session metadata, never terminal history.</span>
              <span className="footer-connection">{connectionState === "live" ? "Live stream" : selectedHost.status === "offline" ? "Last-known metadata" : "Awaiting host"}</span>
            </footer>
          </div>
        )}
      </section>
      {pairingCode && pairingExpiresAt && onDismissPairing ? (
        <div className="pairing-dialog-backdrop">
          <section className="pairing-dialog" role="dialog" aria-modal="true" aria-labelledby="pairing-title">
            <button className="pairing-dialog-close" onClick={onDismissPairing} aria-label="Close pairing dialog">×</button>
            <p className="eyebrow">ADD A TRUSTED HOST</p>
            <h2 id="pairing-title">Link a Mac</h2>
            <p className="pairing-dialog-copy">Enter this one-time code in Axo on the Mac you want to link. It expires at {new Date(pairingExpiresAt).toLocaleTimeString()}.</p>
            <strong className="pairing-dialog-code">{pairingCode}</strong>
            <a className="auth-primary-button" href={`axo://pair/${pairingCode}`}>Open Axo on this Mac</a>
            <button className="auth-secondary-button" onClick={onCopyPairingCode}>Copy code</button>
          </section>
        </div>
      ) : null}
    </main>
  );
}

export type { TerminalRegistry };
