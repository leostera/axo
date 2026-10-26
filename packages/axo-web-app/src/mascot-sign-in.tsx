import { useRef, type MouseEvent } from "react";
import { AxoMascot, type AxoMascotHandle } from "./axo-mascot";

/** Long enough for the hands to come up before the browser leaves for Cloudflare. */
const COVER_BEFORE_LEAVING_MS = 450;

/** Axo, and the way in. */
export function MascotSignIn({ signInUrl, status, error }: { signInUrl: string; status?: string; error?: string | null }) {
  const mascot = useRef<AxoMascotHandle>(null);

  // No peeking while you sign in.
  const signIn = (event: MouseEvent<HTMLAnchorElement>) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
    event.preventDefault();
    mascot.current?.cover(true);
    window.setTimeout(() => window.location.assign(signInUrl), COVER_BEFORE_LEAVING_MS);
  };

  return (
    <main className="mascot-shell">
      <h1 className="visually-hidden">Axo</h1>
      <AxoMascot ref={mascot} className="mascot" />
      <div className="mascot-actions">
        {status ? <p className="auth-status" role="status">{status}</p> : null}
        {error ? <p className="auth-error" role="alert">{error}</p> : null}
        {status ? null : (
          <a className="auth-primary-button mascot-sign-in" href={signInUrl} onClick={signIn}>
            Continue with Cloudflare
          </a>
        )}
      </div>
    </main>
  );
}
