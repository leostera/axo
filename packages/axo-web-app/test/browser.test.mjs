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
const homeWorkspaceId = "8f8f8f8f-0000-4000-8000-000000000001";
const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

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

const liveStream = "9b1e6f0c-6c1d-4a51-9d0e-1f1b2c3d4e5f";
const historyStream = "41c77dd7-f2dc-4e91-b481-1507b62ec118";

function piEvent(socket, sessionId, sequence, name, data) {
  sendEvent(socket, {
    type: "host.data",
    hostId,
    hostGeneration,
    event: { type: "pi.event", sessionId, piSessionId: "pi-session-1", streamId: liveStream, sequence, name, data },
  });
}

function stored(id, name, data) {
  return { id, hostGeneration, piSessionId: "pi-session-1", streamId: historyStream, sequence: id, name, data, receivedAt: 1_797_600_000_000 + id };
}

async function failWithContext(page, error, context) {
  throw new Error(`${error.message}\npage: ${context.pageErrors.join(" | ")}\ntext: ${await page.locator("body").innerText()}\nconsole: ${context.browserMessages.slice(-20).join(" | ")}\nmethods: ${context.methods.join(",")}`);
}

test("browser chats with Axo on a Mac: history, live replies, new chats, info, account and pairing", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser acceptance test",
  timeout: 60_000,
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
    shells: [{ shellId: 17 }],
    layout: { kind: "pane", shellId: 17 },
    // Active a minute ago: listed. The next chat has been quiet for weeks: behind "Show older chats".
    updatedAt: new Date().toISOString(),
    lastMessageAt: Math.floor(Date.now() / 1000) - 60,
  }, {
    hostId,
    sessionId: 5,
    workspaceId,
    workspaceName: "Browser Workspace",
    name: "Old idea",
    status: "ready",
    hasAgent: true,
    shells: [],
    layout: null,
    // Every snapshot says when it was sent; the chat's own activity is its last message.
    updatedAt: new Date().toISOString(),
    lastMessageAt: Math.floor(Date.now() / 1000) - 3 * 7 * 86_400,
  }, {
    hostId,
    sessionId: 4,
    workspaceId: homeWorkspaceId,
    workspaceName: "Home",
    name: "Plan the week",
    status: "ready",
    hasAgent: true,
    shells: [],
    layout: null,
    updatedAt: new Date().toISOString(),
    lastMessageAt: null,
    createdAt: Math.floor(Date.now() / 1000) - 2 * 3_600,
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
  const prompts = [];
  const keys = [];
  let sessionCreateCount = 0;
  let authenticated = false;
  let pairingRequestCount = 0;
  const apiHttp = createHttpServer((request, response) => {
    const origin = request.headers.origin;
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
      json(response, { code: "B26A-NRKT", expiresAt: new Date(Date.now() + 600_000).toISOString() }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/auth/logout") {
      // The Worker forgetting this browser's sign-in.
      authenticated = false;
      response.statusCode = 204;
      response.end();
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/v1/account/hosts") {
      json(response, { hosts: [host(sessions)] }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === `/api/v1/account/hosts/${hostId}/sessions/1/events`) {
      // Newest first, as the relay sends them.
      json(response, {
        events: [
          stored(4, "message.end", { message: { role: "assistant", content: [{ type: "text", text: "I’ll take a **look**.\n\n## What changed\n\n- The relay now retries with `backoff`\n- History loads newest first\n  - a page at a time\n\n```swift\nlet delay = delays[min(attempt, delays.count - 1)]\n```\n\n| File | Lines |\n|---|---|\n| relay.rs | +42 |\n| peer.ts | -7 |" }] } }),
          stored(3, "message.end", { message: { role: "toolResult", toolCallId: "call-1", content: [{ type: "text", text: "On branch main" }] } }),
          stored(2, "message.end", { message: { role: "assistant", content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "git status" } }] } }),
          stored(1, "message.end", { message: { role: "user", content: [{ type: "text", text: "Review the latest changes." }] } }),
        ],
        next: null,
      }, origin);
      return;
    }
    if (request.method === "GET" && /\/sessions\/\d+\/events$/.test(url.pathname)) {
      json(response, { events: [], next: null }, origin);
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
      } else if (call.method === "axo.remote.workspace.list") {
        reply({ workspaces: [{ workspaceId: homeWorkspaceId, name: "Home", home: true }, { workspaceId, name: "Browser Workspace" }] });
      } else if (call.method === "axo.remote.session.create") {
        sessionCreateCount++;
        assert.equal(call.params.workspaceId, undefined, "a new chat goes to the Mac's Home Workspace");
        const created = {
          hostId,
          sessionId: 2,
          workspaceId: homeWorkspaceId,
          workspaceName: "Home",
          name: "Session 2",
          status: "starting",
          createdAt: Math.floor(Date.now() / 1000),
          hasAgent: true,
          shells: [],
          layout: null,
          updatedAt: new Date().toISOString(),
        };
        sessions.push(created);
        reply({ session: created });
      } else if (call.method === "axo.remote.session.prompt") {
        prompts.push({ sessionId: call.params.sessionId, text: call.params.text });
        reply({ accepted: true });
        // Pi records the message, works, and answers: word by word, then whole.
        const base = prompts.length * 10;
        const sessionId = call.params.sessionId;
        setTimeout(() => {
          piEvent(socket, sessionId, base + 1, "message.end", { message: { role: "user", content: [{ type: "text", text: call.params.text }] } });
          piEvent(socket, sessionId, base + 2, "agent.start", {});
          piEvent(socket, sessionId, base + 3, "message.update", { message: { role: "assistant", content: [{ type: "text", text: "Wor" }] } });
        }, 30);
        setTimeout(() => {
          piEvent(socket, sessionId, base + 4, "message.end", { message: { role: "assistant", content: [{ type: "text", text: `Done with: ${call.params.text}` }] } });
          piEvent(socket, sessionId, base + 5, "agent.end", {});
        }, 400);
      } else if (call.method === "axo.remote.session.key") {
        keys.push(call.params.key);
        reply({ accepted: true });
      } else {
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "unknown method" } }));
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
    vite = await createViteServer({
      configFile: false,
      root: siteRoot,
      define: {
        "import.meta.env.VITE_AXO_API_BASE_URL": JSON.stringify(appUrl),
        __AXO_WEB_BUILD__: JSON.stringify("test"),
      },
      plugins: [react()],
      resolve: { dedupe: ["react", "react-dom"] },
      server: {
        host: "127.0.0.1",
        port: appPort,
        strictPort: true,
        // The wordmark's font and the mascot are shared with the apps, in the repository's assets/.
        fs: { allow: [resolve(siteRoot, "../..")] },
        proxy: {
          "/api": { target: `http://127.0.0.1:${apiPort}`, changeOrigin: true, ws: true },
        },
      },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({
      executablePath: chromePath,
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    });
    const page = await browser.newPage({ viewport: { width: 1440, height: 960 } });
    const context = { pageErrors: [], browserMessages: [], methods };
    page.on("pageerror", (error) => context.pageErrors.push(error.message));
    page.on("console", (message) => context.browserMessages.push(`${message.type()}: ${message.text()}`));
    // AXO_WEB_SHOTS=<dir> keeps a picture of each step, to compare with the phone's.
    const shot = async (name) => {
      if (process.env.AXO_WEB_SHOTS) await page.screenshot({ path: resolve(process.env.AXO_WEB_SHOTS, `web-${name}.png`) });
    };
    const expect = (locator) => locator.waitFor({ timeout: 10_000 }).catch((error) => failWithContext(page, error, context));

    await page.goto(`${appUrl}/`, { waitUntil: "networkidle" });
    // The landing page is Axo and a way in.
    await expect(page.getByRole("img", { name: "Axo" }));
    assert.ok((await page.getByRole("link", { name: "Continue with Cloudflare" }).getAttribute("href"))
      .endsWith("/api/auth/cloudflare/start"), "the landing page starts the Worker's Cloudflare sign-in");

    // Dictation, with a stand-in for the browser's speech recognition.
    await page.addInitScript(() => {
      window.SpeechRecognition = window.webkitSpeechRecognition = class {
        start() {
          setTimeout(() => this.onresult?.({ resultIndex: 0, results: [Object.assign([{ transcript: "and check the logs" }], { isFinal: true })] }), 20);
        }
        stop() { setTimeout(() => this.onend?.(), 0); }
        abort() { this.onend?.(); }
      };
    });
    await page.goto(`${appUrl}/__tests__/chat`, { waitUntil: "networkidle" });
    const chats = page.getByRole("navigation", { name: "Chats" });
    // Every chat in one list by its last message (or creation), as on the Mac, with how long ago.
    // Chats only: a bare terminal Session is not a chat.
    const recent = chats.getByRole("region", { name: "Recent chats" });
    await expect(recent.getByRole("button", { name: "Old idea" }));
    assert.deepEqual(await recent.locator(".chat-row-name").allTextContents(), ["Browser Agent", "Plan the week", "Old idea"]);
    assert.deepEqual(await recent.locator(".chat-row-age").allTextContents(), ["1m", "2h", "3w"]);
    assert.equal(await page.getByText("Standalone Shell").count(), 0);
    assert.equal(await chats.getByRole("button", { name: "Browser Workspace", exact: true }).count(), 0, "no Workspace tree");
    await shot("recent-chats");
    // Nothing is opened on its own: a new chat waits for its first message.
    await expect(page.getByRole("heading", { name: "New chat", exact: true }));
    await expect(page.getByText("What are we working on?"));
    assert.equal(new URL(page.url()).pathname, "/__tests__/chat");
    await shot("new-chat");

    // A chat's history: words, Markdown and the tools Pi used.
    await chats.getByRole("button", { name: "Browser Agent" }).click();
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    await expect(page.getByText("Review the latest changes.", { exact: true }));
    await expect(page.locator("strong", { hasText: "look" }));
    const tool = page.getByTestId("tool-card");
    await expect(tool.getByText("$ git status"));
    await expect(tool.getByLabel("Completed"));
    await expect(tool.getByText("On branch main"));
    await shot("history");

    // The open chat is in the URL: a reload opens it again, and Back goes to where it was before.
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/1`);
    await page.reload({ waitUntil: "networkidle" });
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    await expect(page.getByText("Review the latest changes.", { exact: true }));
    await chats.getByRole("button", { name: "Plan the week" }).click();
    await expect(page.getByRole("heading", { name: "Plan the week", exact: true }));
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/4`);
    await page.goBack();
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/1`);
    // A chat that is gone opens a new one.
    await page.goto(`${appUrl}/__tests__/chat/${hostId}/99`, { waitUntil: "networkidle" });
    await expect(page.getByRole("heading", { name: "New chat", exact: true }));
    await page.waitForFunction(() => location.pathname === "/__tests__/chat", null, { timeout: 5_000 });
    await chats.getByRole("button", { name: "Browser Agent" }).click();
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));

    // Sending: the message shows at once, then Pi's reply as it is written and once it is whole.
    const box = page.getByRole("textbox", { name: "Message" });
    await page.waitForFunction(() => !document.querySelector("textarea[aria-label='Message']")?.disabled, null, { timeout: 10_000 });
    // Pasting puts plain words where the caret is.
    await box.fill("Ship ");
    await box.evaluate((field) => {
      const data = new DataTransfer();
      data.setData("text/plain", "it\r\nnow");
      data.setData("text/html", "<b>it</b>");
      field.setSelectionRange(5, 5);
      field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    assert.equal(await box.inputValue(), "Ship it\nnow");
    // Too long for the Mac: said so, and not sent.
    await box.fill("x".repeat(16_001));
    await expect(page.getByText("Too long to send", { exact: false }));
    assert.equal(await page.getByRole("button", { name: "Send" }).isDisabled(), true);
    // Dictation adds what is said to what is typed.
    await box.fill("Look around");
    await page.getByRole("button", { name: "Dictate" }).click();
    await page.waitForFunction(() => document.querySelector("textarea[aria-label='Message']")?.value === "Look around and check the logs", null, { timeout: 5_000 });
    await page.getByRole("button", { name: "Stop dictating" }).click();
    await expect(page.getByRole("button", { name: "Dictate" }));
    await box.fill("Ship it");
    await box.press("Enter");
    await expect(page.getByText("Done with: Ship it", { exact: true }));
    assert.deepEqual(prompts[0], { sessionId: 1, text: "Ship it" });
    assert.equal(await page.getByTestId("pending-prompt").count(), 0, "the agent's record of the message retires the pending one");
    assert.equal(await box.inputValue(), "");

    // A new chat: its first message starts it in the Mac's Home Workspace.
    await chats.getByRole("button", { name: "Chat", exact: true }).click();
    await expect(page.getByRole("heading", { name: "New chat", exact: true }));
    await box.fill("Start fresh");
    await box.press("Enter");
    await expect(page.getByRole("heading", { name: "Session 2", exact: true }));
    await expect(page.getByText("Done with: Start fresh", { exact: true }));
    assert.equal(sessionCreateCount, 1);
    assert.deepEqual(prompts[1], { sessionId: 2, text: "Start fresh" });
    // The new chat goes to the top of the list, and into the URL.
    assert.equal(await recent.locator(".chat-row-name").first().textContent(), "Session 2");
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/2`);

    // The chat's info.
    await page.getByRole("button", { name: "Chat info" }).click();
    const info = page.getByRole("complementary", { name: "Chat info" });
    await expect(info.getByText("Workspace", { exact: true }));
    await expect(info.getByText("Browser fixture Mac, online"));
    await shot("info");
    await info.getByRole("button", { name: "Close chat info" }).click();

    // The account, its Macs, and pairing another.
    await chats.getByRole("button", { name: "Account and Macs" }).click();
    const account = page.getByRole("navigation", { name: "Account" });
    await expect(account.getByText("Browser fixture Mac"));
    await expect(account.getByText("4 chats"));
    await shot("account");
    await account.getByRole("button", { name: "Pair a Mac" }).click();
    const pairing = page.getByRole("dialog", { name: "Pair a Mac" });
    await expect(pairing.getByText("B26A-NRKT"));
    assert.equal(pairingRequestCount, 1);
    await shot("pairing");
    assert.equal(await pairing.getByRole("link", { name: "Open Axo on this Mac" }).getAttribute("href"), "axo://pair/B26A-NRKT");
    await pairing.getByRole("button", { name: "Close Pair a Mac" }).click();
    await account.getByRole("button", { name: "Back to chats" }).click();
    await expect(chats.getByRole("button", { name: "Browser Agent" }));

    // On a phone-sized screen the layers stack: the conversation first, the chats a swipe or a tap away.
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByRole("button", { name: "Show chats" }));
    const chatsLeft = () => page.locator(".layer-conversation").evaluate((layer) => layer.getBoundingClientRect().left);
    assert.equal(await chatsLeft(), 0);
    await page.getByRole("button", { name: "Show chats" }).click();
    await page.waitForFunction(() => document.querySelector(".layer-conversation").getBoundingClientRect().left > 200, null, { timeout: 5_000 });
    await page.waitForTimeout(500);
    await shot("phone-chats");
    await chats.getByRole("button", { name: "Browser Agent" }).click();
    await page.waitForFunction(() => document.querySelector(".layer-conversation").getBoundingClientRect().left === 0, null, { timeout: 5_000 });
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    await shot("phone-chat");
    await page.emulateMedia({ colorScheme: "dark" });
    await shot("phone-chat-dark");
    await page.setViewportSize({ width: 1440, height: 960 });
    await shot("desktop-dark");
    await page.emulateMedia({ colorScheme: "light" });

    // Signed out, the app is the sign-in; signed in, it is the chats; signing out ends it.
    await page.goto(`${appUrl}/app`, { waitUntil: "networkidle" });
    await expect(page.getByRole("link", { name: "Continue with Cloudflare" }));
    authenticated = true;
    await page.reload({ waitUntil: "networkidle" });
    await expect(page.getByRole("navigation", { name: "Chats" }).getByRole("button", { name: "Browser Agent" }));
    await page.getByRole("navigation", { name: "Chats" }).getByRole("button", { name: "Settings" }).click();
    await page.getByRole("dialog", { name: "Settings" }).getByRole("button", { name: "Sign out" }).click();
    await expect(page.getByRole("link", { name: "Continue with Cloudflare" }));
    assert.deepEqual(context.pageErrors, []);
    assert.ok(!methods.some((method) => method.startsWith("axo.remote.terminal")), "the browser follows chats, not terminals");
  } finally {
    await browser?.close();
    await vite?.close();
    for (const socket of sockets) socket.close(1000, "test complete");
    websocketServer.close();
    await new Promise((resolveClose) => apiHttp.close(() => resolveClose()));
  }
});
