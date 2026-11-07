import assert from "node:assert/strict";
import { createServer as createNetServer } from "node:net";
import { once } from "node:events";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import react from "@vitejs/plugin-react";
import { chromium } from "playwright-core";
import { createServer as createViteServer } from "vite";

const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const shareId = "AbCdEfGhIjKlMnOpQrStUv";

// What `/axo-share` publishes (packages/pi-axo/src/share.ts), already redacted.
const bash = (id, command, output, status = "completed") => ({
  id, role: "tool", text: "", timestamp: 1_760_616_100_000, images: [],
  tool: { callId: id, name: "bash", kind: "shell", subtitle: null, command, status, output, outputTruncated: false },
});
const snapshot = {
  version: 1,
  title: "axo: share sessions",
  emoji: "🔗",
  model: { provider: "anthropic", id: "claude-opus-4-5", name: "Claude Opus 4.5" },
  publishedAt: "2026-10-16T12:00:00.000Z",
  messages: [
    { id: "u1", role: "user", text: "Publish this with token [redacted:api-key]", timestamp: 1_760_616_000_000, tool: null, images: [] },
    { id: "a1#0", role: "tool", text: "", timestamp: 1_760_616_000_000, images: [], tool: { callId: "t0", name: "axo_set_title", kind: "generic", subtitle: null, command: null, status: "completed", output: "Session named 🔗 axo: share sessions.", outputTruncated: false } },
    bash("a1#1", "ls ~/axo", "README.md"),
    { id: "a1#2", role: "assistant", text: "Done. **Redacted** before upload.\n\n```ts\nconst answer: number = 42; // the answer\n```", timestamp: 1_760_616_300_000, tool: null, images: [] },
    bash("a2#0", "seq 1 100", Array.from({ length: 100 }, (_, n) => `line ${n + 1}`).join("\n")),
    bash("a2#1", "false", "", "failed"),
    bash("a2#2", "true", ""),
    bash("a2#3", "echo [redacted:local-filesystem-path]", "ok"),
    { id: "a3#0", role: "assistant", text: "All four ran.", timestamp: 1_760_616_600_000, tool: null, images: [] },
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

test("a shared session renders read-only from its published snapshot", { timeout: 120_000 }, async () => {
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
    // The web app from its sources, as a workspace link gives it, even where it is an installed
    // package (Bazel's node_modules): Vite only converts the CommonJS imports of sources.
    resolve: { dedupe: ["react", "react-dom"], alias: { "@axo/web-app": resolve(import.meta.dirname, "../src/main.tsx") } },
    server: { host: "127.0.0.1", port, strictPort: true, fs: { allow: [resolve(siteRoot, "../.."), resolve(realpathSync(resolve(siteRoot, "index.html")), "../../..")] } },
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
    assert.equal(await page.title(), "🔗 axo: share sessions · Axo");
    assert.match(await page.locator(".share-facts").textContent(), /Claude Opus 4\.5 · 5 tool calls · 10 min/);
    assert.equal(await page.locator(".textarea, textarea").count(), 0, "a shared session has no message box");

    // Redactions read as markers; their kind is in the tooltip.
    assert.equal(await page.locator(".share-user .redacted").getAttribute("title"), "Redacted before sharing: api key");
    assert.equal(await page.locator(".share-assistant strong").first().textContent(), "Redacted");
    // Code is coloured, and copied as it was written.
    assert.equal(await page.locator(".md-code .tok-keyword").first().textContent(), "const");
    assert.equal(await page.locator(".md-code code").textContent(), "const answer: number = 42; // the answer");
    // The title tool is the header, not a step.
    assert.equal(await page.getByText("axo_set_title").count(), 0);

    // One call: a quiet line, folded, with its output a click away.
    const first = page.locator("details.share-tool").first();
    assert.equal(await first.evaluate(details => details.open), false);
    assert.ok(await page.getByText("$ ls ~/axo").first().isVisible());
    await first.locator("summary").click();
    assert.equal(await first.locator(".share-output").textContent(), "README.md");

    // Four calls in a row fold into one line; long output shows its start, then all of it.
    const steps = page.locator("details.share-steps");
    assert.match(await steps.locator(":scope > summary").textContent(), /4 tool calls.*bash ×4.*1 failed/);
    assert.equal(await steps.evaluate(details => details.open), false);
    await steps.locator(":scope > summary").click();
    const long = steps.locator("details.share-tool").first();
    await long.locator("summary").click();
    assert.equal((await long.locator(".share-output").textContent()).split("\n").length, 20);
    await long.getByRole("button", { name: "Show all 100 lines" }).click();
    assert.equal((await long.locator(".share-output").textContent()).split("\n").length, 100);

    // `e` opens or closes every call at once.
    await page.keyboard.press("e");
    assert.equal(await page.locator("details.share-tool:not([open])").count(), 0);
    await page.keyboard.press("e");
    assert.equal(await page.locator("details.share-tool[open]").count(), 0);

    assert.equal(await page.locator("a[download]").first().getAttribute("href"), `/s/${shareId}/axo-share-sessions.jsonl`);
    if (process.env.AXO_WEB_SHOTS) await page.screenshot({ path: resolve(process.env.AXO_WEB_SHOTS, "shared-session.png"), fullPage: true });

    // A snapshot inlined into the page, as the Worker serves it, draws without asking the API.
    const before = requests.length;
    await page.route(`**/s/${shareId}/inlined`, async route => {
      const html = await (await route.fetch()).text();
      const inline = JSON.stringify({ shareId, snapshot: { ...snapshot, title: "inlined title" } }).replace(/</g, "\\u003c");
      await route.fulfill({ contentType: "text/html", body: html.replace("</head>", `<script id="axo-share-snapshot" type="application/json">${inline}</script></head>`) });
    });
    await page.goto(`http://127.0.0.1:${port}/s/${shareId}/inlined`);
    await page.getByRole("heading", { name: "inlined title" }).waitFor();
    assert.equal(requests.length, before, "an inlined snapshot needs no request");

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
