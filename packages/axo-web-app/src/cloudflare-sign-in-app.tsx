import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { hostPairingCreateResultSchema } from "@axo/protocol/v1";

const RemoteTerminalApp = lazy(async () => {
  const module = await import("./remote-terminal-app");
  return { default: module.RemoteTerminalApp };
});

type SessionResponse =
  | { authenticated: false }
  | {
      authenticated: true;
      profile: { email: string | null; name: string | null };
      csrfToken: string;
      expiresAt: string;
    };

type AuthenticatedSession = Extract<SessionResponse, { authenticated: true }>;

const authBaseUrl = import.meta.env.VITE_AXO_AUTH_API_BASE_URL || window.location.origin;

export function CloudflareSignInApp() {
  const [session, setSession] = useState<AuthenticatedSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [pairingCode, setPairingCode] = useState<string | null>(null);
  const [pairingExpiresAt, setPairingExpiresAt] = useState<string | null>(null);
  const [creatingPairing, setCreatingPairing] = useState(false);
  const startUrl = useMemo(() => new URL("/api/auth/cloudflare/start", authBaseUrl).href, []);
  const meUrl = useMemo(() => new URL("/api/auth/me", authBaseUrl).href, []);
  const logoutUrl = useMemo(() => new URL("/api/auth/logout", authBaseUrl).href, []);
  const pairingUrl = useMemo(() => new URL("/api/v1/account/host-pairings", authBaseUrl).href, []);

  const refreshSession = useCallback(async (signal?: AbortSignal) => {
    setLoading(true);
    try {
      const response = await fetch(meUrl, {
        credentials: "include",
        cache: "no-store",
        headers: { Accept: "application/json" },
        signal,
      });
      if (!response.ok) throw new Error(`Sign-in status unavailable (${response.status})`);
      const body = await response.json() as SessionResponse;
      setSession(body.authenticated ? body : null);
      setError(null);
    } catch (cause) {
      if (signal?.aborted) return;
      setSession(null);
      setError(cause instanceof Error ? cause.message : "Could not check Axo sign-in status");
    } finally {
      if (!signal?.aborted) setLoading(false);
    }
  }, [meUrl]);

  useEffect(() => {
    const controller = new AbortController();
    void refreshSession(controller.signal);
    return () => controller.abort();
  }, [refreshSession]);

  const createPairing = useCallback(async () => {
    if (!session || creatingPairing) return;
    setCreatingPairing(true);
    setPairingCode(null);
    setPairingExpiresAt(null);
    setError(null);
    try {
      const response = await fetch(pairingUrl, {
        method: "POST",
        credentials: "include",
        cache: "no-store",
        headers: { "X-Axo-CSRF": session.csrfToken },
      });
      const result = hostPairingCreateResultSchema.safeParse(await response.json());
      if (!response.ok || !result.success)
        throw new Error(`Pairing request failed (${response.status})`);
      setPairingCode(result.data.code);
      setPairingExpiresAt(result.data.expiresAt);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not create a pairing code");
    } finally {
      setCreatingPairing(false);
    }
  }, [creatingPairing, pairingUrl, session]);

  const dismissPairing = useCallback(() => {
    setPairingCode(null);
    setPairingExpiresAt(null);
  }, []);

  const copyPairingCode = useCallback(async () => {
    if (!pairingCode) return;
    try {
      await navigator.clipboard.writeText(pairingCode);
      setError(null);
    } catch {
      setError("Clipboard access is unavailable. Select and copy the code instead.");
    }
  }, [pairingCode]);

  const signOut = useCallback(async () => {
    if (!session) return;
    setPairingCode(null);
    setPairingExpiresAt(null);
    setError(null);
    try {
      const response = await fetch(logoutUrl, {
        method: "POST",
        credentials: "include",
        cache: "no-store",
        headers: { "X-Axo-CSRF": session.csrfToken },
      });
      if (!response.ok) throw new Error(`Sign out failed (${response.status})`);
      setSession(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not sign out");
    }
  }, [logoutUrl, session]);

  if (!loading && session) {
    return (
      <Suspense fallback={<main className="app-loading" role="status">Opening your Axo workspace…</main>}>
        <RemoteTerminalApp
          profile={session.profile}
          accountError={error}
          pairingCode={pairingCode}
          pairingExpiresAt={pairingExpiresAt}
          creatingPairing={creatingPairing}
          onCreatePairing={() => void createPairing()}
          onCopyPairingCode={() => void copyPairingCode()}
          onDismissPairing={dismissPairing}
          onSignOut={() => void signOut()}
        />
      </Suspense>
    );
  }

  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="auth-title">
        <div className="auth-brand-mark" aria-hidden="true">A</div>
        <p className="auth-eyebrow">AXO REMOTE ACCESS</p>
        <h1 id="auth-title">Sign in to Axo</h1>
        <p className="auth-description">
          Use your Cloudflare identity to create and access your private Axo account.
        </p>
        {loading ? <p className="auth-status" role="status">Checking sign-in status…</p> : null}
        {error ? <p className="auth-error" role="alert">{error}</p> : null}
        {!loading && !session ? (
          <a className="auth-primary-button" href={startUrl}>Continue with Cloudflare</a>
        ) : null}
        <p className="auth-footnote">Axo receives your Cloudflare identity only. It does not request access to manage your Cloudflare resources.</p>
      </section>
    </main>
  );
}
