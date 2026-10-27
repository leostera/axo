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

  // The iPhone app's sign-in, for the browser: Axo, the wordmark, and one way in.
  return (
    <main className="signin">
      <div className="signin-hero">
        <AxoMascot ref={mascot} className="mascot" />
        <h1 className="signin-wordmark" aria-label="Axo">axo</h1>
        {/* Yes, olotl. Axo is an axolotl. */}
        <p className="signin-tagline">your agentic experience olotl</p>
      </div>
      <div className="signin-actions">
        {status ? <p className="signin-status" role="status">{status}</p> : null}
        {error ? <p className="signin-error" role="alert">{error}</p> : null}
        {status ? null : (
          <a className="cloudflare-button" href={signInUrl} onClick={signIn}>
            Continue with Cloudflare
          </a>
        )}
        <p className="signin-build">axo web · {__AXO_WEB_BUILD__}</p>
      </div>
    </main>
  );
}
