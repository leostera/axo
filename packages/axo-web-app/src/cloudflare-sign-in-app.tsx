import { useCallback, useEffect, useMemo, useState } from "react";

type SessionResponse =
  | { authenticated: false }
  | {
      authenticated: true;
      profile: { email: string | null; name: string | null };
      csrfToken: string;
      expiresAt: string;
    };

const authBaseUrl = import.meta.env.VITE_AXO_AUTH_API_BASE_URL || window.location.origin;

export function CloudflareSignInApp() {
  const [session, setSession] = useState<Extract<SessionResponse, { authenticated: true }> | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const startUrl = useMemo(() => new URL("/api/auth/cloudflare/start", authBaseUrl).href, []);
  const meUrl = useMemo(() => new URL("/api/auth/me", authBaseUrl).href, []);
  const logoutUrl = useMemo(() => new URL("/api/auth/logout", authBaseUrl).href, []);

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

  const signOut = useCallback(async () => {
    if (!session) return;
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

  return (
    <main className="auth-shell">
      <section className="auth-card" aria-labelledby="auth-title">
        <div className="auth-brand-mark" aria-hidden="true">A</div>
        <p className="auth-eyebrow">AXO REMOTE ACCESS</p>
        <h1 id="auth-title">{session ? "You’re signed in" : "Sign in to Axo"}</h1>
        <p className="auth-description">
          {session
            ? "Your Cloudflare identity is connected to an Axo account."
            : "Use your Cloudflare identity to create and access your private Axo account."}
        </p>
        {loading ? <p className="auth-status" role="status">Checking sign-in status…</p> : null}
        {error ? <p className="auth-error" role="alert">{error}</p> : null}
        {!loading && session ? (
          <div className="auth-account">
            <strong>{session.profile.name || "Cloudflare account"}</strong>
            {session.profile.email ? <span>{session.profile.email}</span> : null}
            <button className="auth-secondary-button" onClick={() => void signOut()}>Sign out</button>
          </div>
        ) : null}
        {!loading && !session ? (
          <a className="auth-primary-button" href={startUrl}>Continue with Cloudflare</a>
        ) : null}
        <p className="auth-footnote">Axo receives your Cloudflare identity only. It does not request access to manage your Cloudflare resources.</p>
      </section>
    </main>
  );
}
