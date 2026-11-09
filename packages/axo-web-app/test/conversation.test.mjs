// The conversation's rendering, in Chrome against a fake cloud: what a reply streaming, a flood of
// replies, and a reply in another chat cost, and that the newest row stays in view (RFD0040).
//
// AXO_WEB_BENCH=<file.json> also writes what was measured there, with where it came from.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { existsSync, realpathSync, writeFileSync } from "node:fs";
import { once } from "node:events";
import { resolve } from "node:path";
import { test } from "node:test";
import react from "@vitejs/plugin-react";
import { chromium } from "playwright-core";
import { WebSocketServer } from "ws";
import { createServer as createViteServer } from "vite";

const hostId = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sid = (n) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
/** The chat under test, and another on the same Mac. */
const open = sid(1);
const other = sid(2);
/** How long the open chat is: long enough that rendering all of it on every update would show. */
const HISTORY = 400;

function record(cursor, message) {
  const entry = { type: "message", id: `entry-${cursor}`, parentId: cursor > 1 ? `entry-${cursor - 1}` : null, timestamp: now, message };
  return { cursor, id: entry.id, format: "pi/3", hash: `sha256:${cursor.toString(16).padStart(64, "0")}`, line: JSON.stringify(entry) };
}

const paragraph = (n) => `Step ${n}: and then the next step of the plan, with \`code\` and **bold** words, `.repeat(3);
function history(count) {
  const lines = [];
  for (let i = 1; i <= count; i++) {
    lines.push(record(i, i % 2
      ? { role: "user", content: [{ type: "text", text: `Question ${i}` }] }
      : { role: "assistant", timestamp: 1_700_000_000_000 + i, content: [{ type: "text", text: `${paragraph(i)}\n\n- one\n- two\n\n${paragraph(i + 1)}` }] }));
  }
  return lines;
}

function listed(sessionId, name, head) {
  return {
    hostId, sessionId, epoch: 1, head, status: "ready",
    metadata: { name, emoji: null, folderName: null, hasAgent: true, createdAt: null, lastMessageAt: Math.floor(Date.now() / 1000) - 60, archived: false },
  };
}

async function freePort() {
  const server = createNetServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((done) => server.close(done));
  return port;
}

/** A cloud with one Mac and two chats, whose socket the test drives. */
async function startCloud() {
  const transcripts = new Map([[open, history(HISTORY)], [other, history(4)]]);
  const sessions = [listed(open, "Long chat", HISTORY), listed(other, "Other chat", 4)];
  const sockets = new Set();
  const http = createHttpServer((request, response) => {
    response.setHeader("Content-Type", "application/json");
    if (request.url?.startsWith("/api/v1/account/apps")) return response.end(JSON.stringify({ apps: [] }));
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not here" }));
  });
  const wss = new WebSocketServer({ noServer: true });
  http.on("upgrade", (request, socket, head) => wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws)));
  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("message", (raw) => {
      const call = JSON.parse(raw.toString());
      if (!call.method || call.id === undefined) return;
      const reply = (result) => socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, result }));
      if (call.method === "axo.client.hello" && call.params.protocolVersion !== 2) {
        return socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32602, message: "Invalid params" } }));
      }
      if (call.method === "axo.client.hello" || call.method === "axo.client.refresh") {
        return reply({ hosts: [{ hostId, hostGeneration: "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230", label: "Mac", hostKind: "macos", online: true, lastSeenAt: now }], sessions });
      }
      if (call.method === "axo.client.session.open") {
        const lines = transcripts.get(call.params.sessionId) ?? [];
        const records = call.params.have ? lines.filter((line) => line.cursor > call.params.have.cursor) : lines.slice(-call.params.window.last);
        return reply({ epoch: 1, records, cursor: lines.length, older: null, progress: [] });
      }
      socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "unknown method" } }));
    });
  });
  const send = (method, params) => { for (const socket of sockets) socket.send(JSON.stringify({ jsonrpc: "2.0", method, params })); };
  return {
    http, wss,
    /** Writes a line of `sessionId`, as Pi would. */
    write(sessionId, message) {
      const lines = transcripts.get(sessionId);
      const next = record(lines.length + 1, message);
      lines.push(next);
      send("axo.client.session.records", { sessionId, epoch: 1, records: [next], cursor: next.cursor });
    },
    progress(sessionId, snapshot) { send("axo.client.session.progress", { sessionId, slot: "message", snapshot }); },
    status(sessionId, status) {
      const index = sessions.findIndex((session) => session.sessionId === sessionId);
      sessions[index] = { ...sessions[index], status };
      send("axo.client.sessions", { hostId, sessions: [sessions[index]] });
    },
  };
}

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

/** Twenty updates of a reply being written, five a second, then its record. */
async function stream(cloud, sessionId, words = 20) {
  const at = Date.now();
  cloud.status(sessionId, "working");
  for (let i = 1; i <= words; i++) {
    const text = Array.from({ length: i }, (_, n) => `word${n + 1}`).join(" ");
    cloud.progress(sessionId, { message: { role: "assistant", timestamp: at, content: [{ type: "text", text }] } });
    await sleep(200);
  }
  cloud.write(sessionId, { role: "assistant", timestamp: at, content: [{ type: "text", text: Array.from({ length: words }, (_, n) => `word${n + 1}`).join(" ") }] });
  cloud.progress(sessionId, null);
  cloud.status(sessionId, "ready");
}

test("a long chat renders incrementally: a reply streaming renders only itself, and the end stays in view", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser test",
  timeout: 120_000,
}, async () => {
  const cloud = await startCloud();
  let vite;
  let browser;
  const results = {};
  try {
    cloud.http.listen(0, "127.0.0.1");
    await once(cloud.http, "listening");
    const apiPort = cloud.http.address().port;
    const appPort = await freePort();
    const appUrl = `http://127.0.0.1:${appPort}`;
    vite = await createViteServer({
      configFile: false,
      root: siteRoot,
      define: { "import.meta.env.VITE_AXO_API_BASE_URL": JSON.stringify(appUrl), __AXO_WEB_BUILD__: JSON.stringify("test") },
      plugins: [react()],
      resolve: { dedupe: ["react", "react-dom"], alias: { "@axo/web-app": resolve(import.meta.dirname, "../src/main.tsx") } },
      server: {
        host: "127.0.0.1", port: appPort, strictPort: true,
        fs: { allow: [resolve(siteRoot, "../.."), resolve(realpathSync(resolve(siteRoot, "index.html")), "../../..")] },
        proxy: { "/api": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true, ws: true } },
      },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ executablePath: chromePath, headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"] });
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    // The main thread's long tasks, as the browser reports them.
    await page.addInitScript(() => {
      window.__axoLongTasks = [];
      new PerformanceObserver((list) => { for (const entry of list.getEntries()) window.__axoLongTasks.push(entry.duration); })
        .observe({ type: "longtask", buffered: true });
    });

    const counts = () => page.evaluate(() => ({ ...(window.__axoRenders ?? {}) }));
    const longTasks = () => page.evaluate(() => window.__axoLongTasks.splice(0).reduce((sum, ms) => sum + ms, 0));
    /** Waits until nothing renders for a while: what is being let out is all out. */
    const quiet = async () => {
      let last = JSON.stringify(await counts());
      for (let i = 0; i < 100; i++) {
        await sleep(400);
        const now = JSON.stringify(await counts());
        if (now === last) return;
        last = now;
      }
      throw new Error("the conversation never stopped rendering");
    };
    /**
     * How far from the end the transcript is in each frame it changes size, as painted: observed
     * by a ResizeObserver made after the app's, whose callbacks run after the app's in the same
     * frame, after layout and before paint. Sampling from outside instead reads the page between a
     * render and its frame, which nobody sees.
     */
    const watchEnd = () => page.evaluate(() => {
      const transcript = document.querySelector("[data-testid=transcript]");
      window.__axoEnd = { worst: 0, frames: 0 };
      window.__axoEndObserver?.disconnect();
      window.__axoEndObserver = new ResizeObserver(() => {
        window.__axoEnd.frames += 1;
        const fromEnd = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight;
        window.__axoEnd.worst = Math.max(window.__axoEnd.worst, Math.round(fromEnd));
      });
      window.__axoEndObserver.observe(transcript.firstElementChild);
    });
    const endSeen = () => page.evaluate(() => window.__axoEnd);
    const delta = (before, after) => Object.fromEntries(Object.keys({ ...before, ...after })
      .map((key) => [key, (after[key] ?? 0) - (before[key] ?? 0)]).filter(([, value]) => value));
    /** The transcript's geometry, and the last row's bottom against the message box's top. */
    const geometry = () => page.evaluate(() => {
      const transcript = document.querySelector("[data-testid=transcript]");
      const rows = transcript.querySelectorAll(".transcript-column > *");
      const last = [...rows].filter((row) => row.matches(".message, .pending-message"))?.at(-1);
      const footer = document.querySelector(".conversation-footer").getBoundingClientRect();
      return {
        rows: rows.length,
        fromEnd: Math.round(transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight),
        lastVisible: last ? last.getBoundingClientRect().bottom <= footer.bottom && last.getBoundingClientRect().bottom > 0 : false,
        lastText: last?.textContent.slice(0, 40) ?? null,
        nodes: document.getElementsByTagName("*").length,
      };
    });

    // Opening the long chat: how long until its newest row is on screen, and how much is in the page.
    const started = Date.now();
    await page.goto(`${appUrl}/__tests__/chat/${hostId}/${open}`, { waitUntil: "domcontentloaded" });
    await page.getByText(`Question ${HISTORY - 1}`).waitFor({ timeout: 20_000 });
    await page.waitForFunction(() => {
      const transcript = document.querySelector("[data-testid=transcript]");
      return transcript && transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 2;
    });
    results.open = { ms: Date.now() - started, ...(await geometry()), longTaskMs: Math.round(await longTasks()) };

    // A reply streaming into the open chat.
    await quiet();
    let before = await counts();
    await longTasks();
    await watchEnd();
    await stream(cloud, open);
    await page.getByText("word20", { exact: false }).last().waitFor();
    await sleep(1500);
    results.stream = {
      renders: delta(before, await counts()),
      longTaskMs: Math.round(await longTasks()),
      painted: await endSeen(),
      end: await geometry(),
    };

    // A flood: thirty replies, ten a second.
    await quiet();
    before = await counts();
    await watchEnd();
    cloud.status(open, "working");
    for (let i = 1; i <= 30; i++) {
      cloud.write(open, { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: `Flood reply ${i}: ${paragraph(i)}` }] });
      await sleep(100);
    }
    cloud.status(open, "ready");
    await page.getByText("Flood reply 30:").waitFor({ timeout: 30_000 });
    await page.waitForFunction(() => {
      const transcript = document.querySelector("[data-testid=transcript]");
      return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 2;
    }, null, { timeout: 30_000 });
    results.flood = {
      renders: delta(before, await counts()),
      longTaskMs: Math.round(await longTasks()),
      painted: await endSeen(),
      end: await geometry(),
    };

    // A reply streaming in another chat: nothing here should render.
    await quiet();
    before = await counts();
    await stream(cloud, other);
    await sleep(500);
    results.elsewhere = { renders: delta(before, await counts()), longTaskMs: Math.round(await longTasks()) };

    // Hidden: the tab behind another. A hidden document runs no animation frames (the HTML
    // standard's "update the rendering" skips it), which headless Chrome does not do on its own: so
    // the page is told it is hidden, and its frames wait until it is shown. A reply and a message
    // after it arrive meanwhile; once back, both are there at once.
    await page.evaluate(() => {
      const held = [];
      window.__axoShow = () => {
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "visible" });
        Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
        window.requestAnimationFrame = window.__axoFrame;
        document.dispatchEvent(new Event("visibilitychange"));
        for (const callback of held.splice(0)) window.__axoFrame(callback);
      };
      window.__axoFrame = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = (callback) => { held.push(callback); return 0; };
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    cloud.write(open, { role: "assistant", timestamp: Date.now(), content: [{ type: "text", text: `While away: ${paragraph(1)}` }] });
    await sleep(150);
    cloud.write(open, { role: "assistant", timestamp: Date.now() + 1, content: [{ type: "text", text: "And after it" }] });
    await sleep(3000);
    const whileHidden = await page.evaluate(() => document.body.innerText.includes("And after it"));
    const hidden = "hidden";
    await page.evaluate(() => window.__axoShow());
    const backAt = Date.now();
    await page.getByText("And after it").waitFor({ timeout: 30_000 });
    results.hidden = { visibility: hidden, shownWhileHidden: whileHidden, msToShowOnReturn: Date.now() - backAt };

    console.log("CONVERSATION", JSON.stringify(results, null, 2));
    if (process.env.AXO_WEB_BENCH) {
      const commit = (() => { try { return execFileSync("git", ["rev-parse", "--short", "HEAD"]).toString().trim(); } catch { return null; } })();
      const dirty = (() => { try { return execFileSync("git", ["status", "--porcelain", "--", "packages/axo-web-app"], { cwd: resolve(import.meta.dirname, "../../..") }).toString().trim().length > 0; } catch { return null; } })();
      writeFileSync(process.env.AXO_WEB_BENCH, JSON.stringify({
        at: new Date().toISOString(), commit, dirty, chrome: browser.version(), node: process.version, history: HISTORY, results,
      }, null, 2));
    }
    assert.deepEqual(errors, []);

    // What is shown: the newest row, at the end.
    assert.ok(results.stream.end.lastVisible, "after a reply, its row is in view");
    assert.ok(results.flood.end.lastVisible && results.flood.end.lastText.startsWith("Flood reply 30"), "after the flood, its last reply is in view");
    if (process.env.AXO_WEB_BASELINE) return;
    assert.ok(results.hidden.msToShowOnReturn < 300, `what arrived while the tab was hidden shows on return: ${JSON.stringify(results.hidden)}`);
    // What it costs: a reply streaming renders itself, not the rows above it; another chat, nothing.
    assert.ok((results.stream.renders.Message ?? 0) <= 4, `the rows above a streaming reply stay as they are: ${JSON.stringify(results.stream.renders)}`);
    // Each reply renders as the row above it once: as it arrives, and once all of its words are out.
    assert.ok((results.flood.renders.Message ?? 0) <= 2 * 30 + 4, `a flood renders each new reply a few times, not every row: ${JSON.stringify(results.flood.renders)}`);
    // Following, every frame painted shows the end.
    assert.ok(results.stream.painted.worst <= 1 && results.stream.painted.frames > 0, `a streaming reply keeps the end in view in every frame: ${JSON.stringify(results.stream.painted)}`);
    assert.ok(results.flood.painted.worst <= 1, `a flood keeps the end in view in every frame: ${JSON.stringify(results.flood.painted)}`);
    assert.equal(results.elsewhere.renders.Message ?? 0, 0, "a reply in another chat renders no row here");
    assert.equal(results.elsewhere.renders.Growing ?? 0, 0);
  } finally {
    await browser?.close();
    await vite?.close();
    cloud.wss.close();
    await new Promise((done) => cloud.http.close(() => done()));
  }
});
