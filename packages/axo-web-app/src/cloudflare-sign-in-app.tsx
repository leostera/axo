import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { hostPairingCreateResultSchema } from "@axo/protocol/v1";

const RemoteTerminalApp = lazy(async () => {
  const module = await import("./remote-terminal-app");
  return { default: module.RemoteTerminalApp };
});

/** `GET /api/auth/me` for a signed-in person; anyone else gets 401. */
type AuthenticatedSession = {
  authenticated: true;
  accountId: string;
  profile: { email: string | null; name: string | null };
  expiresAt: string;
};

const authBaseUrl = import.meta.env.VITE_AXO_AUTH_API_BASE_URL || window.location.origin;

export function CloudflareSignInApp() {
  const [session, setSession] = useState<AuthenticatedSession | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [pairingCode, setPairingCode] = useState<string | null>(null);
  const [pairingExpiresAt, setPairingExpiresAt] = useState<string | null>(null);
  const [creatingPairing, setCreatingPairing] = useState(false);
  // The Worker sends the person to Cloudflare, then back here with a session cookie.
  const signInUrl = useMemo(() => new URL("/api/auth/cloudflare/start", authBaseUrl).href, []);
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
      if (!response.ok) {
        // Release the unread error body so the request completes.
        await response.body?.cancel();
        if (response.status !== 401) throw new Error(`Sign-in status unavailable (${response.status})`);
        setSession(null);
        setError(null);
        return;
      }
      setSession(await response.json() as AuthenticatedSession);
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

  // Ends this browser's sign-in only; the server forgets it, and the cookie is cleared.
  const signOut = useCallback(async () => {
    try {
      await fetch(logoutUrl, { method: "POST", credentials: "include", cache: "no-store" });
    } finally {
      setSession(null);
      setPairingCode(null);
      setPairingExpiresAt(null);
    }
  }, [logoutUrl]);

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
          Sign in with your Cloudflare account to reach your Axo Macs from anywhere.
        </p>
        {loading ? <p className="auth-status" role="status">Checking sign-in status…</p> : null}
        {error ? <p className="auth-error" role="alert">{error}</p> : null}
        {!loading && !session ? (
          <a className="auth-primary-button" href={signInUrl}>Continue with Cloudflare</a>
        ) : null}
        <p className="auth-footnote">Axo only learns who you are (your Cloudflare user ID and email). It never has access to manage your Cloudflare resources.</p>
      </section>
    </main>
  );
}
