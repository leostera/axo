import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { MascotSignIn } from "./mascot-sign-in";

const ChatApp = lazy(async () => {
  const module = await import("./chat/chat-app.tsx");
  return { default: module.ChatApp };
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

  // Ends this browser's sign-in only; the server forgets it, and the cookie is cleared.
  const signOut = useCallback(async () => {
    try {
      await fetch(logoutUrl, { method: "POST", credentials: "include", cache: "no-store" });
    } finally {
      setSession(null);
    }
  }, [logoutUrl]);

  if (!loading && session) {
    return (
      <Suspense fallback={<main className="app-loading" role="status">Opening your chats…</main>}>
        <ChatApp profile={session.profile} pairingUrl={pairingUrl} onSignOut={() => void signOut()} />
      </Suspense>
    );
  }

  return (
    <MascotSignIn
      signInUrl={signInUrl}
      status={loading ? "Checking sign-in status…" : undefined}
      error={error}
    />
  );
}
