import React from "react";
import { createRoot } from "react-dom/client";
import { CloudflareSignInApp } from "./cloudflare-sign-in-app";
import { LandingPage } from "./landing-page";
import "./styles.css";

const RemoteTerminalApp = React.lazy(() =>
  import("./remote-terminal-app").then(({ RemoteTerminalApp }) => ({ default: RemoteTerminalApp })),
);

const path = window.location.pathname;
const isAppPath = path === "/app" || path === "/app/";
const isRemoteTerminalTestPath = import.meta.env.DEV && path === "/__tests__/terminal";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {isAppPath
      ? <CloudflareSignInApp />
      : isRemoteTerminalTestPath
        ? <React.Suspense fallback={null}><RemoteTerminalApp /></React.Suspense>
        : <LandingPage />}
  </React.StrictMode>,
);
