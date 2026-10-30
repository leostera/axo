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
const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/app.axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

function session(sessionId, shellId) {
  return {
    hostId,
    sessionId,
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

function json(response, value, origin) {
  response.statusCode = 200;
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

test("browser discovers hosts, renders live PTY output, sends input, and uses Cmd+T", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser acceptance test",
  timeout: 45_000,
}, async () => {
  const sessions = [{
    hostId,
    sessionId: 1,
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
  }];
  const sockets = new Set();
  const methods = [];
  const inputShellIds = [];
  const apiRequests = [];
  let inputText = "";
  let sessionCreateCount = 0;
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
    if (request.method === "GET" && url.pathname === "/v1/hosts") {
      json(response, { hosts: [host(sessions)] }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === `/v1/hosts/${hostId}/sessions`) {
      if (url.searchParams.get("hostGeneration") !== hostGeneration) {
        response.statusCode = 409;
        response.end("stale host generation");
        return;
      }
      json(response, { host: host(sessions), sessions }, origin);
      return;
    }
    response.statusCode = 404;
    response.end("not found");
  });
  const websocketServer = new WebSocketServer({ noServer: true, maxPayload: 65_536 });
  apiHttp.on("upgrade", (request, socket, head) => {
    if (request.url !== `/v1/hosts/${hostId}/client`) {
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
      } else if (call.method === "axo.remote.session.create") {
        sessionCreateCount++;
        const created = session(2, 29);
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
    const apiBaseUrl = appUrl;
    let apiBaseUrlWasInjected = false;
    const apiUrlForBrowser = {
      name: "axo-browser-test-api-url",
      enforce: "pre",
      transform(code, id) {
        if (id.includes("remote-terminal-app.tsx")) {
          const transformed = code.replaceAll("import.meta.env.VITE_AXO_API_BASE_URL", JSON.stringify(apiBaseUrl));
          apiBaseUrlWasInjected = transformed.includes(JSON.stringify(apiBaseUrl));
          return transformed;
        }
        return null;
      },
    };
    vite = await createViteServer({
      configFile: false,
      root: siteRoot,
      plugins: [apiUrlForBrowser, react()],
      server: {
        host: "127.0.0.1",
        port: appPort,
        strictPort: true,
        proxy: {
          "/v1": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true, ws: true },
        },
      },
      logLevel: "error",
    });
    await vite.listen();
    await fetch(`${appUrl}/`);
    assert.ok(apiBaseUrlWasInjected, "Vite did not inject the isolated API URL into the packaged web application");
    const proxyCheck = await fetch(`${appUrl}/v1/hosts`);
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
    await page.goto(appUrl, { waitUntil: "networkidle" });
    await page.getByRole("button", { name: /Browser fixture Mac/ }).waitFor({ timeout: 10_000 }).catch(async (error) => {
      throw new Error(`${error.message}\npage: ${pageErrors.join(" | ")}\ntext: ${await page.locator("body").innerText()}\nconsole: ${browserMessages.join(" | ")}\napi: ${apiRequests.join(" | ")}`);
    });
    await page.getByRole("button", { name: /Session 1/ }).waitFor({ timeout: 10_000 });
    await page.waitForFunction(() => document.querySelector(".connection-chip.live"), null, { timeout: 10_000 });
    await page.locator(".terminal-output .xterm-rows").first().waitFor({ timeout: 10_000 });
    assert.equal(await page.locator(".terminal-pane").count(), 2);

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
    await page.getByRole("button", { name: /Session 2/ }).waitFor({ timeout: 10_000 });
    assert.equal(sessionCreateCount, 1);
    assert.ok(methods.includes("axo.remote.terminal.input"));
    assert.ok(methods.includes("axo.remote.session.create"));
    assert.deepEqual(pageErrors, []);
  } finally {
    await browser?.close();
    await vite?.close();
    for (const socket of sockets) socket.close(1000, "test complete");
    websocketServer.close();
    await new Promise((resolveClose) => apiHttp.close(() => resolveClose()));

  }
});
