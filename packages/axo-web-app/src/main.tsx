import React from "react";
import { createRoot } from "react-dom/client";
import { CloudflareSignInApp } from "./cloudflare-sign-in-app";
import { LandingPage } from "./landing-page";
import "./styles.css";

const ChatApp = React.lazy(() =>
  import("./chat/chat-app.tsx").then(({ ChatApp }) => ({ default: ChatApp })),
);

const path = window.location.pathname;
const isAppPath = path === "/app" || path === "/app/";
// The signed-in app without signing in, for the browser tests against a fake API.
const isChatTestPath = import.meta.env.DEV && path === "/__tests__/chat";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {isAppPath
      ? <CloudflareSignInApp />
      : isChatTestPath
        ? <React.Suspense fallback={null}><ChatApp profile={{ name: "Fixture", email: "fixture@example.test" }} pairingUrl="/api/v1/account/host-pairings" /></React.Suspense>
        : <LandingPage />}
  </React.StrictMode>,
);
