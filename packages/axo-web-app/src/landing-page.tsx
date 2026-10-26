import { useEffect } from "react";
import { MascotSignIn } from "./mascot-sign-in";

const authBaseUrl = import.meta.env.VITE_AXO_AUTH_API_BASE_URL || window.location.origin;

export function LandingPage() {
  // Someone already signed in goes straight to their Macs.
  useEffect(() => {
    const controller = new AbortController();
    fetch(new URL("/api/auth/me", authBaseUrl), { credentials: "include", cache: "no-store", signal: controller.signal })
      .then(async (response) => {
        await response.body?.cancel();
        if (response.ok) window.location.replace("/app");
      })
      .catch(() => {});
    return () => controller.abort();
  }, []);

  return <MascotSignIn signInUrl={new URL("/api/auth/cloudflare/start", authBaseUrl).href} />;
}
