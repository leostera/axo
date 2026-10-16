import React from "react";
import { createRoot } from "react-dom/client";
import { RemoteTerminalApp } from "./remote-terminal-app";
import "@xterm/xterm/css/xterm.css";
import "./styles.css";

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <RemoteTerminalApp />
  </React.StrictMode>,
);
