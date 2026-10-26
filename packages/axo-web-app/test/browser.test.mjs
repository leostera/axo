import assert from "node:assert/strict";
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { existsSync } from "node:fs";
import { once } from "node:events";
import { resolve } from "node:path";
import { test } from "node:test";
import react from "@vitejs/plugin-react";
import { chromium } from "playwright-core";
import { WebSocketServer } from "ws";
import { createServer as createViteServer } from "vite";

const hostId = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
const hostGeneration = "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230";
const subscriptionId = "53c8b056-a7ba-4354-9659-dda29f57850a";
const workspaceId = "04d389d1-9896-420e-9b42-fc7835522937";
const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

function session(sessionId, shellId) {
  return {
    hostId,
    sessionId,
    workspaceId,
    workspaceName: "Browser Workspace",
    name: sessionId === 1 ? "Browser Agent" : `Session ${sessionId}`,
    emoji: "🦀",
    status: "ready",
    hasAgent: true,
    shells: [{ shellId }],
    layout: { kind: "pane", shellId },
    updatedAt: now,
  };
}

function host(sessions) {
  return {
    hostId,
    hostGeneration,
    label: "Browser fixture Mac",
    hostKind: "macos",
    status: "online",
    stale: false,
    lastSeenAt: now,
    sessions,
  };
}

function json(response, value, origin, status = 200) {
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json");
  response.setHeader("Cache-Control", "private, no-store");
  response.setHeader("Access-Control-Allow-Origin", origin ?? "http://127.0.0.1:5173");
  response.setHeader("Access-Control-Allow-Credentials", "true");
  response.setHeader("Vary", "Origin");
  response.end(JSON.stringify(value));
}

async function freePort() {
  const server = createNetServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((resolveClose, rejectClose) => server.close((error) => error ? rejectClose(error) : resolveClose()));
  return port;
}

function sendEvent(socket, event) {
  socket.send(JSON.stringify({
    jsonrpc: "2.0",
    method: "axo.host.event",
    params: { subscriptionId, event },
  }));
}

async function assertPanesFillSlots(page) {
  const sizes = await page.locator(".layout-child").evaluateAll((slots) => slots.map((slot) => {
    const pane = slot.querySelector(":scope > .terminal-pane");
    return pane ? {
      paneWidth: pane.getBoundingClientRect().width,
      slotWidth: slot.getBoundingClientRect().width,
    } : null;
  }));
  assert.equal(sizes.length, 2);
  for (const size of sizes) {
    assert.ok(size, "split slot should contain its terminal pane");
    assert.ok(Math.abs(size.paneWidth - size.slotWidth) < 1, `pane width ${size.paneWidth} should fill slot width ${size.slotWidth}`);
  }
}

test("browser discovers hosts, renders live PTY output, sends input, and uses Cmd+T", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser acceptance test",
  timeout: 45_000,
}, async () => {
  const sessions = [{
    hostId,
    sessionId: 1,
    workspaceId,
    workspaceName: "Browser Workspace",
    name: "Browser Agent",
    emoji: "🦀",
    status: "ready",
    hasAgent: true,
    shells: [{ shellId: 17 }, { shellId: 18 }],
    layout: {
      kind: "split",
      id: "dce950b5-54b0-43eb-a56c-f807c927a881",
      direction: "right",
      ratio: 0.5,
      first: { kind: "pane", shellId: 17 },
      second: { kind: "pane", shellId: 18 },
    },
    updatedAt: now,
  }, {
    hostId,
    sessionId: 3,
    workspaceId: null,
    workspaceName: null,
    name: "Standalone Shell",
    hasAgent: false,
    shells: [{ shellId: 19 }],
    layout: { kind: "pane", shellId: 19 },
    updatedAt: now,
  }];
  const sockets = new Set();
  const methods = [];
  const inputShellIds = [];
  const apiRequests = [];
  let inputText = "";
  let sessionCreateCount = 0;
  let standaloneCreateCount = 0;
  let authenticated = false;
  let appOrigin = "";
  let pairingRequestCount = 0;
  const apiHttp = createHttpServer((request, response) => {
    apiRequests.push(`${request.method} ${request.url} origin=${request.headers.origin ?? "none"}`);
    const origin = request.headers.origin;
    if (request.method === "OPTIONS") {
      response.statusCode = 204;
      response.setHeader("Access-Control-Allow-Origin", origin ?? "null");
      response.setHeader("Access-Control-Allow-Credentials", "true");
      response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      response.setHeader("Access-Control-Allow-Headers", "Content-Type");
      response.end();
      return;
    }
    const url = new URL(request.url, "http://127.0.0.1");
    if (request.method === "GET" && url.pathname === "/api/auth/me") {
      if (!authenticated) {
        json(response, { error: "Sign in required" }, origin, 401);
        return;
      }
      json(response, {
        authenticated: true,
        accountId: "6b0f0e0e-2c43-4b8e-9d0a-0d8f7b2b9c11",
        profile: { email: "fixture@example.test", name: null },
        expiresAt: now,
      }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/host-pairings") {
      pairingRequestCount++;
      json(response, {
        code: "B26A-NRKT",
        expiresAt: "2026-10-16T12:10:00.000Z",
      }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/auth/logout") {
      // The Worker forgetting this browser's sign-in.
      authenticated = false;
      response.statusCode = 204;
      response.setHeader("Access-Control-Allow-Origin", origin ?? "null");
      response.setHeader("Access-Control-Allow-Credentials", "true");
      response.end();
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/v1/account/hosts") {
      json(response, { hosts: [host(sessions)] }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === `/api/v1/account/hosts/${hostId}/sessions`) {
      if (url.searchParams.get("hostGeneration") !== hostGeneration) {
        response.statusCode = 409;
        response.end("stale host generation");
        return;
      }
      json(response, { host: host(sessions), sessions }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === `/api/v1/account/hosts/${hostId}/sessions/1/events`) {
      json(response, {
        events: [
          {
            id: 1,
            hostGeneration,
            piSessionId: "pi-session-1",
            streamId: "41c77dd7-f2dc-4e91-b481-1507b62ec118",
            sequence: 1,
            name: "message.end",
            data: { message: { role: "user", content: [{ type: "text", text: "Review the latest changes." }] } },
            receivedAt: 1_797_600_000_000,
          },
          {
            id: 2,
            hostGeneration,
            piSessionId: "pi-session-1",
            streamId: "41c77dd7-f2dc-4e91-b481-1507b62ec118",
            sequence: 2,
            name: "message.end",
            data: { message: { role: "assistant", content: [{ type: "text", text: "I’ll take a look." }] } },
            receivedAt: 1_797_600_000_001,
          },
        ],
        next: null,
      }, origin);
      return;
    }
    response.statusCode = 404;
    response.end("not found");
  });
  const websocketServer = new WebSocketServer({ noServer: true, maxPayload: 65_536 });
  apiHttp.on("upgrade", (request, socket, head) => {
    if (request.url !== `/api/v1/account/hosts/${hostId}/client`) {
      socket.destroy();
      return;
    }
    websocketServer.handleUpgrade(request, socket, head, (websocket) => {
      websocketServer.emit("connection", websocket, request);
    });
  });
  websocketServer.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("message", (raw) => {
      const call = JSON.parse(raw.toString());
      if (!call.method || call.method === "axo.transport.ack") return;
      methods.push(call.method);
      const reply = (result) => socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, result }));
      if (call.method === "axo.protocol.negotiate") {
        reply({ protocolVersion: 1, methods: [], deliveryCredits: { frames: 32, bytes: 131072 } });
      } else if (call.method === "axo.host.subscribe") {
        reply({ subscriptionId });
        setTimeout(() => sendEvent(socket, {
          type: "host.presence",
          hostId,
          hostGeneration,
          status: "online",
          observedAt: now,
        }), 20);
      } else if (call.method === "axo.remote.terminal.resize") {
        reply({ accepted: true, rows: call.params.rows, columns: call.params.columns });
      } else if (call.method === "axo.remote.terminal.input") {
        const text = Buffer.from(call.params.data, "base64").toString("utf8");
        inputText += text;
        inputShellIds.push(call.params.shellId);
        reply({ accepted: true, sequence: call.params.sequence });
        if (inputText.includes("\r")) {
          setTimeout(() => sendEvent(socket, {
            type: "host.data",
            hostId,
            hostGeneration,
            event: {
              type: "terminal.output",
              sessionId: 1,
              shellId: call.params.shellId,
              sequence: 0,
              data: Buffer.from("\r\nREMOTE_INPUT_ACCEPTED\r\n").toString("base64"),
            },
          }), 20);
        }
      } else if (call.method === "axo.remote.workspace.session.create") {
        sessionCreateCount++;
        assert.equal(call.params.workspaceId, workspaceId);
        const created = {
          hostId,
          sessionId: 2,
          workspaceId,
          workspaceName: "Browser Workspace",
          name: "Session 2",
          emoji: "🌱",
          status: "starting",
          hasAgent: true,
          shells: [],
          layout: null,
          updatedAt: now,
        };
        sessions.push(created);
        reply({ session: created });
      } else if (call.method === "axo.remote.session.create") {
        standaloneCreateCount++;
        const created = {
          hostId,
          sessionId: 4,
          workspaceId: null,
          workspaceName: null,
          name: "Session 4",
          hasAgent: false,
          shells: [],
          layout: null,
          updatedAt: now,
        };
        sessions.push(created);
        reply({ session: created });
      } else {
        socket.send(JSON.stringify({
          jsonrpc: "2.0",
          id: call.id,
          error: { code: -32601, message: "unknown method" },
        }));
      }
    });
  });

  let vite;
  let browser;
  try {
    apiHttp.listen(0, "127.0.0.1");
    await once(apiHttp, "listening");
    const apiPort = apiHttp.address().port;
    const appPort = await freePort();
    const appUrl = `http://127.0.0.1:${appPort}`;
    appOrigin = appUrl;
    const apiBaseUrl = appUrl;
    vite = await createViteServer({
      configFile: false,
      root: siteRoot,
      define: { "import.meta.env.VITE_AXO_API_BASE_URL": JSON.stringify(apiBaseUrl) },
      plugins: [react()],
      resolve: { dedupe: ["react", "react-dom"] },
      server: {
        host: "127.0.0.1",
        port: appPort,
        strictPort: true,
        proxy: {
          "/v1": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true, ws: true },
          "/api": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true, ws: true },
          // Cloudflare Access serves this on the app's own origin in production.
          "/cdn-cgi/access": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true },
        },
      },
      logLevel: "error",
    });
    await vite.listen();
    await fetch(`${appUrl}/`);
    const proxyCheck = await fetch(`${appUrl}/api/v1/account/hosts`);
    assert.equal(proxyCheck.status, 200, `Vite API proxy failed: ${await proxyCheck.text()}`);
    browser = await chromium.launch({
      executablePath: chromePath,
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 960 } });
    const pageErrors = [];
    const browserMessages = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("request", (request) => browserMessages.push(`request: ${request.url()}`));
    page.on("console", (message) => browserMessages.push(`${message.type()}: ${message.text()}`));
    page.on("requestfailed", (request) => browserMessages.push(`request failed: ${request.url()} ${request.failure()?.errorText ?? ""}`));
    page.on("response", (response) => { if (response.status() >= 400) browserMessages.push(`HTTP ${response.status()}: ${response.url()}`); });
    await page.goto(`${appUrl}/`, { waitUntil: "networkidle" });
    assert.equal(await page.getByRole("heading", { name: "Pick up where your Mac left off." }).count(), 1);
    await page.getByRole("link", { name: "Continue to Axo" }).click();
    await page.getByRole("heading", { name: "Sign in to Axo" }).waitFor({ timeout: 10_000 });
    await page.goto(`${appUrl}/__tests__/terminal`, { waitUntil: "networkidle" });
    await page.getByRole("button", { name: /Browser fixture Mac/ }).waitFor({ timeout: 10_000 }).catch(async (error) => {
      throw new Error(`${error.message}\npage: ${pageErrors.join(" | ")}\ntext: ${await page.locator("body").innerText()}\nconsole: ${browserMessages.join(" | ")}\napi: ${apiRequests.join(" | ")}`);
    });
    await page.getByRole("button", { name: /Browser Agent/ }).waitFor({ timeout: 10_000 });
    await page.getByText("Workspaces", { exact: true }).waitFor({ timeout: 10_000 });
    await page.getByText("Standalone Sessions", { exact: true }).waitFor({ timeout: 10_000 });
    await page.getByRole("heading", { name: /Browser Agent/ }).waitFor({ timeout: 10_000 });
    await page.getByText("I’ll take a look.", { exact: true }).waitFor({ timeout: 10_000 });
    await page.waitForFunction(() => document.querySelector(".connection-chip.live"), null, { timeout: 10_000 });
    await page.locator(".terminal-output .xterm-rows").first().waitFor({ timeout: 10_000 });
    assert.equal(await page.locator(".terminal-pane").count(), 2);
    await assertPanesFillSlots(page);

    const liveText = "LIVE_BROWSER_OUTPUT";
    for (const socket of sockets) {
      sendEvent(socket, {
        type: "host.data",
        hostId,
        hostGeneration,
        event: {
          type: "terminal.output",
          sessionId: 1,
          shellId: 17,
          sequence: 1,
          data: Buffer.from(`${liveText}\r\n`).toString("base64"),
        },
      });
    }
    await page.waitForFunction((needle) =>
      document.querySelector(".terminal-pane:first-child .terminal-output .xterm-rows")
        ?.textContent?.includes(needle),
    liveText, { timeout: 10_000 });
    await assertPanesFillSlots(page);

    const focusedPane = page.locator(".terminal-pane").nth(1);
    await focusedPane.locator(".terminal-output").click();
    assert.ok((await focusedPane.getAttribute("class")).includes("focused"));
    await page.keyboard.type("browser-remote-input");
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => [...document.querySelectorAll(".terminal-pane")][1]
      ?.querySelector(".terminal-output .xterm-rows")?.textContent?.includes("REMOTE_INPUT_ACCEPTED"), null, { timeout: 10_000 });
    assert.match(inputText, /browser-remote-input\r/);
    assert.ok(inputShellIds.length > 0 && inputShellIds.every((shellId) => shellId === 18));

    await page.keyboard.press("Meta+t");
    await page.getByRole("button", { name: /Session 2/ }).waitFor({ timeout: 10_000 }).catch(async (error) => {
      throw new Error(`${error.message}\npage: ${pageErrors.join(" | ")}\ntext: ${await page.locator("body").innerText()}\nconsole: ${browserMessages.join(" | ")}\nmethods: ${methods.join(",")}`);
    });
    assert.equal(sessionCreateCount, 1);
    await page.getByRole("button", { name: /Standalone Shell/ }).click();
    await page.keyboard.press("Meta+t");
    await page.getByRole("button", { name: /Session 4/ }).waitFor({ timeout: 10_000 });
    assert.equal(standaloneCreateCount, 1);
    assert.ok(methods.includes("axo.remote.terminal.input"));
    assert.ok(methods.includes("axo.remote.workspace.session.create"));
    assert.ok(methods.includes("axo.remote.session.create"));

    await page.goto(`${appUrl}/app`, { waitUntil: "networkidle" });
    await page.getByRole("link", { name: "Continue with Cloudflare" }).waitFor({ timeout: 10_000 });
    assert.equal(await page.getByRole("heading", { name: "Sign in to Axo" }).count(), 1);
    assert.ok((await page.getByRole("link", { name: "Continue with Cloudflare" }).getAttribute("href"))
      .endsWith("/api/auth/cloudflare/start"), "signing in starts the Worker's Cloudflare sign-in");

    authenticated = true;
    await page.reload({ waitUntil: "networkidle" });
    await page.getByRole("heading", { name: /Browser Agent/ }).waitFor({ timeout: 10_000 });
    await page.waitForFunction(() => document.querySelector(".connection-chip.live"), null, { timeout: 10_000 });
    assert.equal(await page.locator(".terminal-pane").count(), 2);
    await page.getByRole("button", { name: "Link a Mac" }).click();
    await page.getByRole("dialog", { name: "Link a Mac" }).getByText("B26A-NRKT").waitFor({ timeout: 10_000 });
    assert.equal(pairingRequestCount, 1);
    assert.equal(await page.getByRole("link", { name: "Open Axo on this Mac" }).getAttribute("href"), "axo://pair/B26A-NRKT");
    assert.deepEqual(pageErrors, []);
    await page.getByRole("button", { name: "Close pairing dialog" }).click();
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.getByRole("link", { name: "Continue with Cloudflare" }).waitFor({ timeout: 10_000 });
  } finally {
    await browser?.close();
    await vite?.close();
    for (const socket of sockets) socket.close(1000, "test complete");
    websocketServer.close();
    await new Promise((resolveClose) => apiHttp.close(() => resolveClose()));

  }
});
