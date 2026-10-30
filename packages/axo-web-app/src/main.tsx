import React from "react";
import { createRoot } from "react-dom/client";
import { CloudflareSignInApp } from "./cloudflare-sign-in-app";
import { LandingPage } from "./landing-page";
import { SharedSession } from "./chat/shared-session";
import "./styles.css";

const ChatApp = React.lazy(() =>
  import("./chat/chat-app.tsx").then(({ ChatApp }) => ({ default: ChatApp })),
);

const path = window.location.pathname;
// The app's chats are under /app: /app/<hostId>/<sessionId> is one of them.
const isAppPath = path === "/app" || path.startsWith("/app/");
// The signed-in app without signing in, for the browser tests against a fake API.
const chatTestPath = "/__tests__/chat";
const isChatTestPath = import.meta.env.DEV && (path === chatTestPath || path.startsWith(`${chatTestPath}/`));
const sharedSessionId = /^\/s\/([A-Za-z0-9_-]{22})(?:\/[^/]+)?\/?$/.exec(path)?.[1];

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {isAppPath
      ? <CloudflareSignInApp />
      : sharedSessionId
        ? <SharedSession shareId={sharedSessionId} />
        : isChatTestPath
        ? <React.Suspense fallback={null}><ChatApp profile={{ name: "Fixture", email: "fixture@example.test" }} pairingUrl="/api/v1/account/host-pairings" basePath={chatTestPath} /></React.Suspense>
        : <LandingPage />}
  </React.StrictMode>,
);
