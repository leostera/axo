import assert from "node:assert/strict";
import { createServer as createNetServer } from "node:net";
import { once } from "node:events";
import { resolve } from "node:path";
import { test } from "node:test";
import react from "@vitejs/plugin-react";
import { chromium } from "playwright-core";
import { createServer as createViteServer } from "vite";

const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const shareId = "AbCdEfGhIjKlMnOpQrStUv";

// What `/axo-share` publishes (packages/pi-axo/src/share.ts), already redacted.
const snapshot = {
  version: 1,
  title: "axo: share sessions",
  publishedAt: "2026-10-16T12:00:00.000Z",
  messages: [
    { id: "u1", role: "user", text: "Publish this with token [redacted:api-key]", timestamp: 1, tool: null, images: [] },
    { id: "a1#0", role: "assistant", text: "Done. **Redacted** before upload.", timestamp: 2, tool: null, images: [] },
    {
      id: "a1#1", role: "tool", text: "", timestamp: 2, images: [],
      tool: { callId: "t1", name: "bash", kind: "shell", subtitle: null, command: "ls ~/axo", status: "completed", output: "README.md", outputTruncated: false },
    },
  ],
};

async function freePort() {
  const server = createNetServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((done, fail) => server.close(error => error ? fail(error) : done()));
  return port;
}

test("a shared session renders read-only from its published snapshot", { timeout: 60_000 }, async () => {
  const port = await freePort();
  const requests = [];
  const vite = await createViteServer({
    configFile: false,
    root: siteRoot,
    define: { __AXO_WEB_BUILD__: JSON.stringify("test") },
    plugins: [react(), {
      name: "public-sessions-fixture",
      configureServer(server) {
        server.middlewares.use((request, response, next) => {
          if (!request.url?.startsWith("/api/")) return next();
          requests.push(request.url);
          if (request.url === `/api/public-sessions/${shareId}`) {
            response.setHeader("Content-Type", "application/json");
            response.end(JSON.stringify(snapshot));
          } else {
            response.statusCode = 404;
            response.end("Not found");
          }
        });
      },
    }],
    resolve: { dedupe: ["react", "react-dom"] },
    server: { host: "127.0.0.1", port, strictPort: true, fs: { allow: [resolve(siteRoot, "../..")] } },
    logLevel: "error",
  });
  await vite.listen();
  const browser = await chromium.launch({ executablePath: chromePath, headless: true, args: ["--no-sandbox"] });
  try {
    const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));

    await page.goto(`http://127.0.0.1:${port}/s/${shareId}/axo-share-sessions`);
    await page.getByRole("heading", { name: "axo: share sessions" }).waitFor();
    assert.ok(await page.getByText("Publish this with token [redacted:api-key]").isVisible());
    assert.equal(await page.locator(".assistant-message strong").textContent(), "Redacted");
    assert.ok(await page.getByText("$ ls ~/axo").isVisible());
    assert.equal(await page.locator("textarea").count(), 0, "a shared session has no message box");
    assert.equal(await page.title(), "axo: share sessions · Axo");
    if (process.env.AXO_WEB_SHOTS) await page.screenshot({ path: resolve(process.env.AXO_WEB_SHOTS, "shared-session.png"), fullPage: true });

    await page.goto(`http://127.0.0.1:${port}/s/AAAAAAAAAAAAAAAAAAAAAA/missing`);
    await page.getByRole("heading", { name: "This shared session isn’t available" }).waitFor();

    assert.deepEqual([...new Set(requests)], [`/api/public-sessions/${shareId}`, "/api/public-sessions/AAAAAAAAAAAAAAAAAAAAAA"],
      "the viewer reads only the public snapshot, never account or session APIs");
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
    await vite.close();
  }
});
