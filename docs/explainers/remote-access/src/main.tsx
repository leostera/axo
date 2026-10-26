import { StrictMode, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button } from "@cloudflare/kumo/components/button";
import { Tabs } from "@cloudflare/kumo/components/tabs";
import { Text } from "@cloudflare/kumo/components/text";
import { MoonIcon, SunIcon } from "@phosphor-icons/react";
import { Playground } from "./playground";
import "@cloudflare/kumo/styles";
import "./styles.css";

function App() {
  // Always show playground
  const [dark, setDark] = useState(() => matchMedia("(prefers-color-scheme: dark)").matches);

  useEffect(() => {
    document.documentElement.dataset.theme = "kumo"; document.documentElement.dataset.mode = dark ? "dark" : "light";
    document.documentElement.classList.toggle("dark", dark);
  }, [dark]);

  return (
    <div className="flex h-screen flex-col gap-3 overflow-hidden p-3">
      <Playground dark={dark} onToggleDark={() => setDark((d) => !d)} />
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
