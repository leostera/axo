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
const workspaceId = "04d389d1-9896-420e-9b42-fc7835522937";
const homeWorkspaceId = "8f8f8f8f-0000-4000-8000-000000000001";
const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const clientHost = { hostId, hostGeneration, label: "Browser fixture Mac", hostKind: "macos", online: true, lastSeenAt: now };

/** A chat as the ClientDO lists it. */
function listed({ sessionId, status = "ready", head = 0, ...metadata }) {
  return {
    hostId, sessionId, epoch: head ? 1 : null, head, status,
    metadata: { name: null, emoji: null, workspaceId: null, workspaceName: null, hasAgent: true, createdAt: null, lastMessageAt: null, archived: false, ...metadata },
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

function notify(socket, method, params) {
  socket.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
}

/** A Session ID for fixture `n`. */
const sid = (n) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;

/** A line of Pi's session file, as the cloud holds it at `cursor`. */
function record(cursor, message) {
  const id = `entry-${cursor}`;
  return {
    cursor, id, format: "pi/3", hash: `sha256:${cursor.toString(16).padStart(64, "0")}`,
    line: JSON.stringify({ type: "message", id, parentId: cursor > 1 ? `entry-${cursor - 1}` : null, timestamp: now, message }),
  };
}

async function failWithContext(page, error, context) {
  throw new Error(`${error.message}\npage: ${context.pageErrors.join(" | ")}\ntext: ${await page.locator("body").innerText()}\nconsole: ${context.browserMessages.slice(-20).join(" | ")}\nmethods: ${context.methods.join(",")}`);
}

test("browser chats with Axo on a Mac: history, live replies, new chats, info, account and pairing", {
  skip: !existsSync(chromePath) && "Set CHROME_PATH to a Chrome/Chromium executable to run this browser acceptance test",
  timeout: 60_000,
}, async () => {
  const sessions = [listed({
    sessionId: sid(1),
    workspaceId,
    workspaceName: "Browser Workspace",
    name: "Browser Agent",
    emoji: "🦀",
    head: 4,
    // Active a minute ago: listed. The next chat has been quiet for weeks.
    lastMessageAt: Math.floor(Date.now() / 1000) - 60,
  }), listed({
    sessionId: sid(5),
    workspaceId,
    workspaceName: "Browser Workspace",
    name: "Old idea",
    lastMessageAt: Math.floor(Date.now() / 1000) - 3 * 7 * 86_400,
  }), listed({
    sessionId: sid(4),
    workspaceId: homeWorkspaceId,
    workspaceName: "Home",
    name: "Plan the week",
    createdAt: Math.floor(Date.now() / 1000) - 2 * 3_600,
  }), listed({
    sessionId: sid(3),
    name: "Standalone Shell",
    hasAgent: false,
    status: null,
  })];
  // Each chat's records in the cloud.
  const transcripts = new Map([[sid(1), [
    record(1, { role: "user", content: [{ type: "text", text: "Review the latest changes." }] }),
    record(2, { role: "assistant", content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "git status" } }] }),
    record(3, { role: "toolResult", toolCallId: "call-1", content: [{ type: "text", text: "On branch main" }] }),
    record(4, { role: "assistant", content: [{ type: "text", text: "I’ll take a **look**.\n\n## What changed\n\n- The relay now retries with `backoff`\n- History loads newest first\n  - a page at a time\n\n```swift\nlet delay = delays[min(attempt, delays.count - 1)]\n```\n\n| File | Lines |\n|---|---|\n| relay.rs | +42 |\n| peer.ts | -7 |" }] }),
  ]]]);
  const sockets = new Set();
  const methods = [];
  const prompts = [];
  const keys = [];
  let sessionCreateCount = 0;
  let authenticated = false;
  let pairingRequestCount = 0;
  const tokenRequests = [];
  const macSignIns = [];
  let macPolls = 0;
  const clientRequests = [];
  /** A ChatGPT device sign-in: polls so far, and whether the person has entered the code. */
  const device = { polls: 0, entered: false };
  // The account's connections (RFD0016), as the Worker lists them.
  const connections = [
    { kind: "host", name: "browser_fixture_mac", hostId, state: "online" },
    { kind: "thirdParty", name: "linear", url: "https://mcp.linear.app/mcp", state: "ready", tools: 23, icon: "https://linear.app/static/apple-touch-icon.png", syncedAt: now, lastError: null },
    { kind: "thirdParty", name: "notion", url: "https://mcp.notion.com/mcp", state: "needsSignIn", tools: 0, syncedAt: null, lastError: "the grant expired and cannot be renewed" },
    { kind: "app", name: "apps.gmail", title: "Gmail", provider: "Google", category: "communication", description: "Read, search, send and organize your mail, and manage Gmail's settings.", permissions: ["Read, search and download every message and attachment", "Send mail and replies, and write drafts", "Label, archive, trash and permanently delete mail"], state: "ready", accounts: [{ account: "ada@example.com", state: "ready", lastError: null }, { account: "grace@example.com", state: "needsSignIn", lastError: "Google refused to renew the grant" }], tools: ["get_profile", "search_messages"], lastError: null },
    { kind: "app", name: "apps.calendar", title: "Google Calendar", provider: "Google", category: "productivity", description: "See and manage your calendars and events.", permissions: ["See every calendar you can reach, and its events"], state: "needsSignIn", accounts: [], tools: ["list_events"], lastError: null },
    { kind: "app", name: "apps.drive", title: "Google Drive", provider: "Google", category: "files", description: "Find, read, upload, organize and share your files.", permissions: ["See and download every file in My Drive and shared drives"], state: "needsSignIn", accounts: [], tools: ["search_files"], lastError: null },
    { kind: "app", name: "apps.hetzner", title: "Hetzner", provider: "Hetzner", category: "developer", description: "Your Hetzner Cloud projects: servers, DNS, firewalls, volumes and storage boxes.", permissions: ["See the project's servers and their usage, and start, stop or restart them"],
      signIn: { kind: "token", helpUrl: "https://console.hetzner.com/projects", named: true, fields: [{ name: "token", label: "API token", help: "In Hetzner Console, open the project, then Security, API tokens, Generate API token.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["list_servers", "request"], lastError: null },
    { kind: "app", name: "apps.chatgpt", title: "ChatGPT", provider: "OpenAI", category: "productivity", description: "Ask ChatGPT's models with your ChatGPT plan, signed in the way Codex is.", permissions: ["Ask ChatGPT's models, using your plan's limits"],
      signIn: { kind: "device" }, state: "needsSignIn", accounts: [], tools: ["respond", "request"], lastError: null },
    { kind: "app", name: "apps.onepassword", title: "1Password", provider: "1Password", category: "security", description: "Your passwords, keys and secure notes, from the 1Password app on your Mac.", permissions: ["Create, change and archive items"],
      signIn: { kind: "mac", setup: "On each Mac, install the 1Password command line, then turn on Integrate with 1Password CLI.", helpUrl: "https://developer.1password.com/docs/cli/reference" },
      state: "ready", accounts: [{ account: "browser_fixture_mac", state: "ready", lastError: null }], tools: ["get_item", "op"], lastError: null },
    { kind: "app", name: "apps.octopus", title: "Octopus Energy", provider: "Octopus Energy", category: "home", description: "Your Octopus Energy account: meters, half-hourly usage and tariff prices.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://octopus.energy/dashboard/new/accounts/personal-details/api-access", named: false, fields: [{ name: "number", label: "Account number", help: "On your bills.", secret: false }, { name: "key", label: "API key", help: "Under API access.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["get_account", "request"], lastError: null },
    { kind: "app", name: "apps.wise", title: "Wise", provider: "Wise", category: "finance", description: "Your Wise balances, transfers, recipients and exchange rates.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://wise.com/settings/api-tokens", named: false, fields: [{ name: "token", label: "API token", help: "In Wise settings.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["list_balances", "request"], lastError: null },
    { kind: "app", name: "apps.telegram", title: "Telegram", provider: "Telegram", category: "communication", description: "A Telegram bot of yours.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://t.me/BotFather", named: false, fields: [{ name: "token", label: "Bot token", help: "From @BotFather.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["send_message", "request"], lastError: null },
    { kind: "app", name: "apps.kraken", title: "Kraken", provider: "Kraken", category: "finance", description: "Your Kraken account.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://pro.kraken.com/app/settings/api", named: true, fields: [{ name: "key", label: "API key", help: "In settings.", secret: true }, { name: "secret", label: "Private key", help: "Shown once.", secret: true }],
        mac: { title: "Sign in with Kraken", presets: [{ id: "read", label: "Read only", description: "See balances, orders and trades." }, { id: "trade", label: "Read and trade", description: "And place and cancel orders." }] } },
      state: "needsSignIn", accounts: [], tools: ["get_balance", "request"], lastError: null },
    { kind: "app", name: "apps.github", title: "GitHub", provider: "GitHub", category: "developer", description: "Your GitHub: repositories, issues, pull requests, code search and notifications.",
      permissions: ["See and change every repository you can reach", "See your notifications"],
      signIn: { kind: "oauth", client: { provider: "github", ready: false, consoleUrl: "https://github.com/settings/developers", redirectUri: "https://axo.leostera.dev/api/v1/connections/oauth/callback" } },
      state: "needsSignIn", accounts: [], tools: ["get_issue", "request"], lastError: null },
    { kind: "app", name: "apps.spotify", title: "Spotify", provider: "Spotify", category: "media", description: "Your Spotify: what is playing, playback on your devices, search, playlists, your library and what you listen to.",
      permissions: ["See what you are playing, on which device, and your queue", "Play, pause, skip, seek and change the volume on your devices"],
      signIn: { kind: "oauth", client: { provider: "spotify", ready: true, consoleUrl: "https://developer.spotify.com/dashboard", redirectUri: "https://axo.leostera.dev/api/v1/connections/oauth/callback" } },
      state: "ready", accounts: [{ account: "ada.l", state: "ready", lastError: null }], tools: ["get_playback", "request"], lastError: null },
    { kind: "app", name: "apps.withings", title: "Withings", provider: "Withings", category: "health", description: "Your Withings health data: weight and body composition, blood pressure, activity, workouts, sleep and ECGs.",
      permissions: ["See your body measures", "See your sleep, night by night"],
      signIn: { kind: "oauth", client: { provider: "withings", ready: false, consoleUrl: "https://developer.withings.com/dashboard/", redirectUri: "https://axo.leostera.dev/api/v1/connections/oauth/callback" } },
      state: "needsSignIn", accounts: [], tools: ["get_measures", "request"], lastError: null },
    { kind: "app", name: "apps.discord", title: "Discord", provider: "Discord", category: "communication", description: "A Discord bot of yours.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://discord.com/developers/applications", named: false, fields: [{ name: "token", label: "Bot token", help: "In the portal.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["send_message", "request"], lastError: null },
    { kind: "app", name: "apps.unifi", title: "UniFi", provider: "Ubiquiti", category: "home", description: "Your UniFi consoles.", permissions: [],
      signIn: { kind: "token", helpUrl: "https://unifi.ui.com/api", named: true, fields: [{ name: "key", label: "API key", help: "At unifi.ui.com.", secret: true }] },
      state: "needsSignIn", accounts: [], tools: ["list_hosts", "request"], lastError: null },
  ];
  const callLog = [
    { callId: "c-3", at: now, sessionId: sid(1), hostId, service: "apps.gmail", tool: "search_messages", targetHostId: null, durationMs: 210, outcome: "ok", error: null, input: { account: "ada@example.com", query: "is:unread" } },
    { callId: "c-2", at: now, sessionId: sid(1), hostId, service: "linear", tool: "list_issues", targetHostId: null, durationMs: 320, outcome: "ok", error: null, input: { team: "AXO" } },
    { callId: "c-1", at: now, sessionId: sid(1), hostId, service: "browser_fixture_mac", tool: "bash", targetHostId: hostId, durationMs: 41, outcome: "ok", error: null, input: { command: "git status", cwd: null, timeoutMs: 60000 } },
  ];
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
    if (request.method === "GET" && url.pathname === "/api/v1/account/connections") {
      json(response, { connections }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/v1/account/connections/log/integrity") {
      json(response, { verified: true, events: callLog.length * 2, head: "ab".repeat(32), brokenAt: null, reason: null }, origin);
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/v1/account/connections/log") {
      const service = url.searchParams.get("service");
      json(response, { records: service ? callLog.filter((record) => record.service === service) : callLog }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.chatgpt/device") {
      json(response, { flow: "flow-1", state: "pending", userCode: "ABCD-1234", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 1, expiresAt: new Date(Date.now() + 900_000).toISOString() }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.chatgpt/device/poll") {
      device.polls++;
      if (!device.entered) {
        json(response, { state: "pending", userCode: "ABCD-1234", verificationUrl: "https://auth.openai.com/codex/device", intervalSeconds: 1, expiresAt: new Date(Date.now() + 900_000).toISOString() }, origin);
        return;
      }
      const chatgpt = connections.find((c) => c.name === "apps.chatgpt");
      chatgpt.accounts = [{ account: "ada@example.com", state: "ready", lastError: null }];
      chatgpt.state = "ready";
      json(response, { state: "done", account: "ada@example.com" }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.github/client") {
      // Setting up an OAuth app's client: sent once, and the secret never comes back.
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        clientRequests.push(JSON.parse(body));
        connections.find((c) => c.name === "apps.github").signIn.client.ready = true;
        json(response, { provider: "github" }, origin);
      });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.github/sign-in") {
      json(response, { signInUrl: "/app/settings/apps/github?signedIn=apps.github" }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.kraken/mac-sign-in") {
      // Kraken's sign-in on a Mac: the page sends the Mac and the choice, then polls until it is done.
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        macSignIns.push(JSON.parse(body));
        json(response, { flow: "kraken-flow", state: "pending", mac: "browser_fixture_mac", expiresAt: now }, origin);
      });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.kraken/mac-sign-in/poll") {
      macPolls++;
      if (macPolls < 2) {
        json(response, { state: "pending", mac: "browser_fixture_mac", expiresAt: now }, origin);
        return;
      }
      const kraken = connections.find((c) => c.name === "apps.kraken");
      kraken.accounts.push({ account: "main", state: "ready", lastError: null });
      json(response, { state: "done", account: "main", expiresAt: now }, origin);
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections/apps.hetzner/token") {
      // Adding a token app's account: Hetzner accepts only its own tokens, and the token is never sent back.
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        const { account, fields } = JSON.parse(body);
        tokenRequests.push({ account, fields });
        if (fields.token !== "hz-good-token") {
          json(response, { error: "Hetzner did not accept this token" }, origin, 400);
          return;
        }
        const hetzner = connections.find((c) => c.name === "apps.hetzner");
        hetzner.accounts.push({ account, state: "ready", lastError: null });
        hetzner.state = "ready";
        json(response, { name: "apps.hetzner", account }, origin);
      });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/account/connections") {
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        // As the Worker does: the name as typed is the title, its slug the name.
        const { name: title, url: serverUrl } = JSON.parse(body);
        const name = title.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
        const connection = { kind: "thirdParty", name, title: name === title ? null : title, url: serverUrl, state: "ready", tools: 3, syncedAt: now, lastError: null };
        connections.push(connection);
        json(response, { connection, signInUrl: null }, origin);
      });
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/auth/logout") {
      // The Worker forgetting this browser's sign-in.
      authenticated = false;
      response.statusCode = 204;
      response.end();
      return;
    }
    response.statusCode = 404;
    response.end("not found");
  });
  const websocketServer = new WebSocketServer({ noServer: true, maxPayload: 65_536 });
  apiHttp.on("upgrade", (request, socket, head) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname !== "/api/v1/account/client" || !/^[A-Za-z0-9_-]{8,64}$/.test(url.searchParams.get("clientId") ?? "")) {
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
    /** Writes a line of a chat, as Pi would, and sends it to the client. */
    const write = (sessionId, message) => {
      const lines = transcripts.get(sessionId) ?? [];
      const next = record(lines.length + 1, message);
      transcripts.set(sessionId, [...lines, next]);
      notify(socket, "axo.client.session.records", { sessionId, epoch: 1, records: [next], cursor: next.cursor });
    };
    const status = (sessionId, value) => {
      const index = sessions.findIndex((session) => session.sessionId === sessionId);
      sessions[index] = { ...sessions[index], status: value };
      notify(socket, "axo.client.sessions", { hostId, sessions: [sessions[index]] });
    };
    socket.on("message", (raw) => {
      const call = JSON.parse(raw.toString());
      if (!call.method || call.method === "axo.client.session.ack" || call.method === "axo.client.session.close") return;
      const reply = (result) => socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, result }));
      if (call.method === "axo.client.hello" || call.method === "axo.client.refresh") {
        methods.push(call.method);
        reply({ hosts: [clientHost], sessions });
        return;
      }
      if (call.method === "axo.client.session.open") {
        methods.push(call.method);
        const lines = transcripts.get(call.params.sessionId) ?? [];
        const records = call.params.have ? lines.filter((line) => line.cursor > call.params.have.cursor) : lines.slice(-call.params.window.last);
        reply({ epoch: lines.length ? 1 : null, records, cursor: lines.length, older: null, progress: [] });
        return;
      }
      if (call.method !== "axo.client.command") {
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "unknown method" } }));
        return;
      }
      const { method, params } = call.params;
      methods.push(method);
      if (method === "axo.remote.workspace.list") {
        reply({ workspaces: [{ workspaceId: homeWorkspaceId, name: "Home", home: true }, { workspaceId, name: "Browser Workspace" }] });
      } else if (method === "axo.remote.session.create") {
        sessionCreateCount++;
        assert.equal(params.workspaceId, undefined, "a new chat goes to the Mac's Home Workspace");
        const createdAt = Math.floor(Date.now() / 1000);
        const created = listed({ sessionId: sid(2), workspaceId: homeWorkspaceId, workspaceName: "Home", name: "Session 2", status: "starting", createdAt });
        sessions.push(created);
        reply({ session: { hostId, sessionId: sid(2), workspaceId: homeWorkspaceId, workspaceName: "Home", name: "Session 2", status: "starting", createdAt, hasAgent: true, shells: [], layout: null, updatedAt: new Date().toISOString() } });
        setTimeout(() => notify(socket, "axo.client.sessions", { hostId, sessions: [created] }), 10);
      } else if (method === "axo.remote.session.prompt") {
        prompts.push({ sessionId: params.sessionId, text: params.text });
        reply({ accepted: true });
        // Pi records the message, works, and answers: word by word, then whole.
        const sessionId = params.sessionId;
        // Pi stamps the reply when it starts; its progress and its record carry the stamp.
        const replyAt = Date.now();
        setTimeout(() => {
          write(sessionId, { role: "user", content: [{ type: "text", text: params.text }] });
          status(sessionId, "working");
          notify(socket, "axo.client.session.progress", { sessionId, slot: "message", snapshot: { message: { role: "assistant", content: [{ type: "text", text: "Wor" }] } } });
        }, 30);
        setTimeout(() => {
          notify(socket, "axo.client.session.progress", { sessionId, slot: "message", snapshot: { message: { role: "assistant", timestamp: replyAt, content: [{ type: "text", text: "Working on it now" }] } } });
        }, 200);
        setTimeout(() => {
          write(sessionId, { role: "assistant", timestamp: replyAt, content: [{ type: "text", text: `Done with: ${params.text}` }] });
          notify(socket, "axo.client.session.progress", { sessionId, slot: "message", snapshot: null });
          status(sessionId, "ready");
        }, params.text === "Ship it" ? 3_000 : 400);
      } else if (method === "axo.remote.session.key") {
        keys.push(params.key);
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
    // A server's icon, from its own site: here, a stand-in.
    await page.route("https://linear.app/static/apple-touch-icon.png", (route) => route.fulfill({
      contentType: "image/svg+xml",
      body: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" rx="22" fill="#5e6ad2"/><path d="M22 60l18 18M22 44l34 34M28 30l42 42M40 22l38 38" stroke="#fff" stroke-width="7" stroke-linecap="round"/></svg>`,
    }));
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

    // Voice, with stand-ins for the microphone and the browser's speech recognition: a guess at
    // the words first, then the words settled.
    await page.addInitScript(() => {
      const result = (transcript, isFinal) => Object.assign([{ transcript }], { isFinal });
      window.SpeechRecognition = window.webkitSpeechRecognition = class {
        start() {
          setTimeout(() => this.onresult?.({ results: [result("and check the", false)] }), 20);
          setTimeout(() => this.onresult?.({ results: [result("and check the logs", true)] }), 400);
        }
        stop() { setTimeout(() => this.onend?.(), 0); }
        abort() {}
      };
      navigator.mediaDevices.getUserMedia = async () => new AudioContext().createMediaStreamDestination().stream;
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
    // Output stays folded until asked for.
    assert.equal(await tool.getByText("On branch main").count(), 0);
    await tool.getByRole("button", { name: "Show output (1 line)" }).click();
    await expect(tool.getByText("On branch main"));
    await shot("history");

    // The open chat is in the URL: a reload opens it again, and Back goes to where it was before.
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/${sid(1)}`);
    await page.reload({ waitUntil: "networkidle" });
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    await expect(page.getByText("Review the latest changes.", { exact: true }));
    await chats.getByRole("button", { name: "Plan the week" }).click();
    await expect(page.getByRole("heading", { name: "Plan the week", exact: true }));
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/${sid(4)}`);
    await page.goBack();
    await expect(page.getByRole("heading", { name: "Browser Agent", exact: true }));
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/${sid(1)}`);
    // A chat that is gone opens a new one, and so does an old integer Session URL.
    for (const gone of [sid(99), "1"]) {
      await page.goto(`${appUrl}/__tests__/chat/${hostId}/${gone}`, { waitUntil: "networkidle" });
      await expect(page.getByRole("heading", { name: "New chat", exact: true }));
      await page.waitForFunction(() => location.pathname === "/__tests__/chat", null, { timeout: 5_000 });
    }
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
    // Voice, as on the phone: an empty box offers it where Send goes. While listening the box
    // shows the words as heard; Stop puts them in the box to read first.
    await box.fill("");
    await page.getByRole("button", { name: "Talk" }).click();
    const listening = page.getByRole("group", { name: "Listening" });
    await expect(listening.locator(".voice-tentative", { hasText: "and check the" }));
    await expect(listening.getByText("and check the logs"));
    await shot("voice-listening");
    await listening.getByRole("button", { name: "Stop" }).click();
    await page.waitForFunction(() => document.querySelector("textarea[aria-label='Message']")?.value === "and check the logs", null, { timeout: 5_000 });
    assert.equal(await page.getByRole("button", { name: "Talk" }).count(), 0, "once something is typed, Send takes its place");
    // Cancel forgets what was heard.
    await box.fill("");
    await page.getByRole("button", { name: "Talk" }).click();
    await listening.getByRole("button", { name: "Cancel" }).click();
    assert.equal(await box.inputValue(), "");
    // Shift-Enter starts a new line rather than sending.
    await box.fill("first line");
    await box.press("Shift+Enter");
    await box.pressSequentially("second line");
    assert.equal(await box.inputValue(), "first line\nsecond line");
    assert.equal(prompts.length, 0, "Shift-Enter sends nothing");
    // On a touch screen Return is how a new line goes in; Send sends.
    await page.evaluate(() => {
      const matchMedia = window.matchMedia.bind(window);
      window.realMatchMedia = window.matchMedia;
      window.matchMedia = query => {
        const list = matchMedia(query);
        return query === "(pointer: coarse)" ? Object.create(list, { matches: { value: true } }) : list;
      };
    });
    await box.fill("on the phone");
    await box.press("Enter");
    assert.equal(await box.inputValue(), "on the phone\n");
    assert.equal(prompts.length, 0, "Return on a touch screen sends nothing");
    await page.evaluate(() => { window.matchMedia = window.realMatchMedia; });
    await box.fill("Ship it");
    await box.press("Enter");
    // While Axo works it says so under the last message, with a way to stop it that asks first.
    const activity = page.getByTestId("agent-activity");
    await expect(activity.getByText("Thinking…"));
    // The reply being written comes in a word at a time, its words fading in; history just appears.
    await expect(page.locator(".word-in", { hasText: "now" }));
    assert.equal(await page.locator(".message:not(.message-enter) .markdown .word-in").count(), 4, "only the live reply's words fade in");
    // Once recorded, the reply carries on as the same message on screen: it is not shown again.
    const writing = await page.locator(".assistant-message", { hasText: "Working on it now" }).elementHandle();
    await shot("working");
    await activity.getByRole("button", { name: "Stop the reply" }).click();
    const confirmStop = page.getByRole("alertdialog", { name: "Stop the reply?" });
    await confirmStop.getByRole("button", { name: "Keep going" }).click();
    assert.equal(keys.length, 0, "keeping going stops nothing");
    await box.press("Escape");
    await confirmStop.getByRole("button", { name: "Stop" }).click();
    await expect(activity.getByText("Stopping…"));
    assert.deepEqual(keys, ["escape"]);
    await expect(page.getByText("Done with: Ship it", { exact: true }));
    assert.ok(await writing.evaluate(element => element.isConnected && element.textContent.includes("Done with: Ship it")), "the recorded reply is the one that was being written");
    assert.deepEqual(prompts[0], { sessionId: sid(1), text: "Ship it" });
    assert.equal(await page.getByTestId("pending-prompt").count(), 0, "the agent's record of the message retires the pending one");
    assert.equal(await box.inputValue(), "");

    // A new chat: its first message starts it in the Mac's Home Workspace.
    await chats.getByRole("button", { name: "New chat", exact: true }).click();
    await expect(page.getByRole("heading", { name: "New chat", exact: true }));
    await box.fill("Start fresh");
    await box.press("Enter");
    await expect(page.getByRole("heading", { name: "Session 2", exact: true }));
    await expect(page.getByText("Done with: Start fresh", { exact: true }));
    assert.equal(sessionCreateCount, 1);
    assert.deepEqual(prompts[1], { sessionId: sid(2), text: "Start fresh" });
    // Send in the listening bar sends what was said.
    await page.getByText("Done with: Start fresh", { exact: true }).waitFor();
    await page.getByRole("button", { name: "Talk" }).click();
    await expect(listening.getByText("and check the logs"));
    await listening.getByRole("button", { name: "Send" }).click();
    await expect(page.getByText("Done with: and check the logs", { exact: true }));
    assert.deepEqual(prompts[2], { sessionId: sid(2), text: "and check the logs" });
    // The new chat goes to the top of the list, and into the URL.
    assert.equal(await recent.locator(".chat-row-name").first().textContent(), "Session 2");
    assert.equal(new URL(page.url()).pathname, `/__tests__/chat/${hostId}/${sid(2)}`);

    // Search finds a chat by its name.
    await chats.getByRole("button", { name: "Search chats" }).click();
    const search = page.getByRole("dialog", { name: "Search" });
    await search.getByRole("textbox", { name: "Search chats" }).fill("week");
    await search.getByRole("button", { name: /Plan the week/ }).click();
    await expect(page.getByRole("heading", { name: "Plan the week", exact: true }));
    await chats.getByRole("button", { name: "Session 2" }).click();

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
    await expect(pairing.getByText("B26A-NRKT", { exact: true }));
    assert.equal(pairingRequestCount, 1);
    await shot("pairing");
    assert.equal(await pairing.getByRole("link", { name: "Open on this Mac" }).getAttribute("href"), "axo://pair/B26A-NRKT");
    // A Mac without Axo: download it, or install it from Terminal with this code.
    assert.equal(await pairing.getByRole("link", { name: "Download Axo" }).getAttribute("href"), "/cdn/Axo.app.zip");
    await expect(pairing.getByText(/^curl -fsSL 'http:\/\/[^']+\/install\?code=B26A-NRKT' \| sh$/));
    await pairing.getByRole("button", { name: "Close Pair a Mac" }).click();
    await account.getByRole("button", { name: "Back to chats" }).click();
    await expect(chats.getByRole("button", { name: "Browser Agent" }));

    // On a phone-sized screen the layers stack: the conversation first, the chats a swipe or a tap away.
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByRole("button", { name: "Chats menu" }));
    const chatsLeft = () => page.locator(".layer-conversation").evaluate((layer) => layer.getBoundingClientRect().left);
    assert.equal(await chatsLeft(), 0);
    await page.getByRole("button", { name: "Chats menu" }).click();
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

    // A server's sign-in comes back to Settings › Apps › MCP servers, which says how it went
    // and drops the query from the URL.
    await page.goto(`${appUrl}/app/settings/apps/mcp?signedIn=linear`, { waitUntil: "networkidle" });
    const servers = page.getByRole("region", { name: "MCP servers" });
    await expect(servers.getByText("Signed in to linear."));
    assert.equal(new URL(page.url()).pathname + new URL(page.url()).search, "/app/settings/apps/mcp");
    await expect(servers.locator(".connection-row strong", { hasText: "notion" }));
    assert.deepEqual(await servers.locator(".connection-row strong").allTextContents(), ["linear", "notion"]);
    assert.equal(await servers.getByRole("button", { name: "Sign in" }).count(), 1, "only the server that needs it offers sign-in");
    await servers.getByRole("button", { name: "Add server" }).click();
    await servers.getByLabel("Name").fill("Docs: work");
    await servers.getByLabel("Server URL").fill("https://docs.example.com/mcp");
    await servers.getByRole("button", { name: "Add", exact: true }).click();
    await expect(servers.getByText("Added Docs: work."));
    await expect(servers.locator(".connection-row strong", { hasText: "Docs: work" }));
    await expect(servers.getByText("codemode.docs_work", { exact: true }));
    await shot("apps-servers");

    // Apps: a grid of every app and server, with filters and what Sessions used lately.
    await servers.getByRole("navigation", { name: "Breadcrumb" }).getByRole("link", { name: "Apps" }).click();
    const apps = page.getByRole("region", { name: "Apps" });
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps");
    await expect(apps.getByRole("link", { name: /Gmail/ }).getByText("2 accounts"));
    const cards = () => apps.locator(".app-card strong").allTextContents();
    assert.deepEqual(await cards(), ["Gmail", "Google Calendar", "Google Drive", "Hetzner", "ChatGPT", "1Password", "Octopus Energy", "Wise", "Telegram", "Kraken", "GitHub", "Spotify", "Withings", "Discord", "UniFi",
      "GitHub MCP", "Cloudflare", "Cloudflare Docs", "Cloudflare Observability", "Cloudflare Browser", "Cloudflare Containers", "Cloudflare Radar", "Hugging Face", "Ahrefs", "Strava", "Stripe", "PayPal",
      "linear", "notion", "Docs: work", "Add MCP server"]);
    await expect(apps.getByText("Log intact · 6 entries"));
    await expect(apps.getByLabel("Recent activity").locator(".call-row strong", { hasText: "Gmail · Search messages" }));
    await page.waitForFunction(() => [...document.querySelectorAll(".app-card img")].every((img) => img.complete && img.naturalWidth > 0));
    assert.equal(await apps.locator(".app-card img").count(), 28, "every app and known server has its maker's logo, and linear its site's icon");
    await shot("apps");
    await apps.getByRole("radio", { name: /^Connected/ }).click();
    assert.deepEqual(await cards(), ["Gmail", "1Password", "Spotify", "linear", "Docs: work"], "only what is connected");
    await apps.getByRole("radio", { name: /^All/ }).first().click();
    await apps.getByRole("radio", { name: /^Files/ }).click();
    assert.deepEqual(await cards(), ["Google Drive"]);
    await apps.getByRole("radio", { name: /^All/ }).last().click();
    await apps.getByLabel("Search apps").fill("cal");
    assert.deepEqual(await cards(), ["Google Calendar"]);
    await apps.getByLabel("Search apps").fill("");
    // A known server has its own page, and is added there as many times as there are accounts, each under a name of the person's.
    await apps.getByRole("link", { name: /Strava/ }).click();
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps/mcp/strava");
    const strava = page.getByRole("region", { name: "Strava" });
    await expect(strava.getByRole("heading", { name: "Strava" }));
    await strava.getByRole("button", { name: "Add account" }).click();
    assert.equal(await strava.getByLabel("Name").inputValue(), "Strava", "the first is named for the server");
    await strava.getByRole("button", { name: "Add and sign in" }).click();
    await expect(strava.getByText("Added Strava."));
    await strava.getByRole("button", { name: "Add account" }).click();
    await strava.getByLabel("Name").fill("Strava: Mariana");
    await strava.getByRole("button", { name: "Add and sign in" }).click();
    await expect(strava.locator(".connection-row strong", { hasText: "Strava: Mariana" }));
    assert.deepEqual(await strava.locator(".connection-row strong").allTextContents(), ["Strava", "Strava: Mariana"]);
    await expect(strava.getByText("codemode.strava_mariana", { exact: true }));
    await shot("apps-server-strava");
    await page.goBack();
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps");
    assert.equal(await apps.getByRole("link", { name: /Strava/ }).locator("small").textContent(), "2 accounts");
    // Every app is a link to its page: ⌘-click opens it in a new tab and leaves this one on Apps.
    assert.equal(await apps.getByRole("link", { name: /Gmail/ }).getAttribute("href"), "/app/settings/apps/gmail");
    assert.equal(await apps.getByRole("link", { name: "See all" }).getAttribute("href"), "/app/settings/apps/activity");
    const opened = page.context().waitForEvent("page");
    await apps.getByRole("link", { name: /Gmail/ }).click({ modifiers: [process.platform === "darwin" ? "Meta" : "Control"] });
    const tab = await opened;
    await tab.waitForLoadState();
    assert.equal(new URL(tab.url()).pathname, "/app/settings/apps/gmail");
    await tab.close();
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps");
    await apps.getByRole("link", { name: /Gmail/ }).click();
    const gmail = page.getByRole("region", { name: "Gmail" });
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps/gmail");
    await expect(gmail.getByRole("heading", { name: "Gmail" }));
    assert.deepEqual(await gmail.locator(".connection-row strong").allTextContents(), ["ada@example.com", "grace@example.com"]);
    assert.equal(await gmail.getByRole("button", { name: "Sign in" }).count(), 1, "the account whose grant was refused offers sign-in");
    assert.equal(await gmail.getByRole("button", { name: "Add account" }).count(), 1);
    assert.equal(await gmail.getByRole("button", { name: "Remove ada@example.com" }).count(), 1);
    assert.equal(await gmail.locator(".permissions li").count(), 3, "the page says what Gmail lets Axo do");
    await expect(gmail.locator(".call-row strong", { hasText: "Search messages" }));
    assert.deepEqual(await gmail.locator(".call-row strong").allTextContents(), ["Search messages"], "only Gmail's activity");
    assert.deepEqual(await gmail.locator(".call-row small").first().textContent(), "ada@example.com · is:unread");
    await shot("apps-gmail");
    await page.emulateMedia({ colorScheme: "dark" });
    await shot("apps-gmail-dark");
    await page.emulateMedia({ colorScheme: "light" });

    await page.setViewportSize({ width: 390, height: 844 });
    await shot("apps-gmail-phone");
    await page.goBack();
    await expect(page.getByRole("region", { name: "Apps" }).getByRole("link", { name: /Gmail/ }).getByText("2 accounts"));
    await shot("apps-phone");
    await page.setViewportSize({ width: 1440, height: 960 });
    await page.goForward();
    await expect(page.getByRole("region", { name: "Gmail" }).getByRole("heading", { name: "Gmail" }));

    // The browser's Back goes back a page; a reload stays on it.
    await page.goBack();
    await expect(page.getByRole("region", { name: "Apps" }).getByRole("link", { name: /Gmail/ }).getByText("2 accounts"));
    await page.getByRole("region", { name: "Apps" }).getByRole("link", { name: "See all" }).click();
    const activityPage = page.getByRole("region", { name: "Activity" });
    await expect(activityPage.locator(".call-row strong", { hasText: "linear · List issues" }));
    assert.deepEqual(await activityPage.locator(".call-row strong").allTextContents(), ["Gmail · Search messages", "linear · List issues", "browser_fixture_mac · Bash"]);
    await page.reload({ waitUntil: "networkidle" });
    await expect(page.getByRole("region", { name: "Activity" }).locator(".call-row strong", { hasText: "linear · List issues" }));
    await page.getByRole("button", { name: "Close settings" }).click();
    await expect(page.getByRole("navigation", { name: "Chats" }).getByRole("button", { name: "Browser Agent" }));
    assert.equal(await page.getByRole("region", { name: "Activity" }).count(), 0);
    assert.ok(!new URL(page.url()).pathname.startsWith("/app/settings"), page.url());

    // A token app: Add account asks for a name and the token, and the token is never shown again.
    await page.goto(`${appUrl}/app/settings/apps/hetzner`, { waitUntil: "networkidle" });
    const hetzner = page.getByRole("region", { name: "Hetzner" });
    await hetzner.getByRole("button", { name: "Add account" }).click();
    await expect(hetzner.getByRole("link", { name: "Open Hetzner" }));
    await hetzner.getByLabel("Account name").fill("Personal");
    await hetzner.getByLabel("API token").fill("hz-bad-token");
    assert.equal(await hetzner.getByLabel("API token").getAttribute("type"), "password");
    await shot("apps-hetzner-add");
    await hetzner.getByRole("button", { name: "Add", exact: true }).click();
    await expect(hetzner.getByText("Hetzner did not accept this token"));
    await hetzner.getByLabel("API token").fill("hz-good-token");
    await hetzner.getByRole("button", { name: "Add", exact: true }).click();
    await expect(hetzner.getByText("Added personal."));
    assert.deepEqual(await hetzner.locator(".connection-row strong").allTextContents(), ["personal"]);
    assert.equal(await hetzner.getByLabel("API token").count(), 0, "the form is gone, and the token with it");
    assert.deepEqual(tokenRequests.map((r) => r.account), ["personal", "personal"]);
    assert.equal((await page.content()).includes("hz-good-token"), false);
    await shot("apps-hetzner");

    // Kraken signs in on a Mac: choose what Axo may do and the Mac, then finish in the browser there.
    await page.goto(`${appUrl}/app/settings/apps/kraken`, { waitUntil: "networkidle" });
    const kraken = page.getByRole("region", { name: "Kraken" });
    await kraken.getByRole("button", { name: "Add account" }).click();
    await kraken.getByLabel("Account name").fill("Main");
    await kraken.getByLabel("Read and trade").check();
    assert.equal(await kraken.getByLabel("Mac").inputValue(), "browser_fixture_mac");
    await shot("apps-kraken-signin");
    await kraken.getByRole("button", { name: "Sign in with Kraken" }).click();
    await expect(kraken.getByText("Finish in the browser on browser_fixture_mac"));
    await shot("apps-kraken-waiting");
    await expect(kraken.getByText("Added main."));
    assert.deepEqual(macSignIns, [{ mac: "browser_fixture_mac", preset: "trade", account: "main" }]);
    assert.deepEqual(await kraken.locator(".connection-row strong").allTextContents(), ["main"]);
    await kraken.getByRole("button", { name: "Add account" }).click();
    await kraken.getByRole("button", { name: "Paste a key instead" }).click();
    await expect(kraken.getByLabel("Private key"));

    // An OAuth app of the person's own: set up its client first, then add accounts.
    await page.goto(`${appUrl}/app/settings/apps/github`, { waitUntil: "networkidle" });
    const github = page.getByRole("region", { name: "GitHub" });
    await expect(github.getByRole("heading", { name: "Set up GitHub" }));
    assert.equal(await github.getByRole("button", { name: "Add account" }).count(), 0, "no account before the client");
    assert.equal(await github.getByLabel("Redirect URI").textContent(), "https://axo.leostera.dev/api/v1/connections/oauth/callback");
    assert.equal(await github.getByRole("link", { name: "Open GitHub" }).getAttribute("href"), "https://github.com/settings/developers");
    await github.getByLabel("Client ID").fill(" Ov23liClient ");
    await github.getByLabel("Client secret").fill("gh-client-secret");
    assert.equal(await github.getByLabel("Client secret").getAttribute("type"), "password");
    await shot("apps-github-setup");
    await github.getByRole("button", { name: "Save", exact: true }).click();
    await expect(github.getByText("GitHub is set up. Add an account."));
    assert.deepEqual(clientRequests, [{ clientId: "Ov23liClient", clientSecret: "gh-client-secret" }]);
    assert.equal(await github.getByLabel("Client secret").count(), 0, "the form is gone, and the secret with it");
    assert.equal((await page.content()).includes("gh-client-secret"), false);
    await expect(github.getByRole("button", { name: "Add account" }));
    await expect(github.getByText("Signs in with your own GitHub OAuth app."));
    await shot("apps-github");
    await github.getByRole("button", { name: "Change client" }).click();
    await expect(github.getByRole("heading", { name: "Change GitHub client" }));
    await github.getByRole("button", { name: "Cancel" }).click();
    await expect(github.getByRole("button", { name: "Add account" }));
    await github.getByRole("button", { name: "Add account" }).click();
    await page.waitForURL(/signedIn=apps\.github/);

    // An OAuth app of another provider, set up: its own logo and maker, and Add account as Google's.
    await page.goto(`${appUrl}/app/settings/apps/spotify`, { waitUntil: "networkidle" });
    const spotify = page.getByRole("region", { name: "Spotify" });
    await expect(spotify.getByRole("heading", { name: "Spotify" }));
    assert.equal(await spotify.locator(".app-meta").textContent(), "Spotify · Media");
    assert.deepEqual(await spotify.locator(".connection-row strong").allTextContents(), ["ada.l"]);
    assert.equal(await spotify.getByRole("button", { name: "Add account" }).count(), 1);
    await page.waitForFunction(() => [...document.querySelectorAll(".app-info img")].every((img) => img.complete && img.naturalWidth > 0));
    await shot("apps-spotify");

    await page.goto(`${appUrl}/app/settings/apps/withings`, { waitUntil: "networkidle" });
    const withingsPage = page.getByRole("region", { name: "Withings" });
    await expect(withingsPage.getByRole("heading", { name: "Set up Withings" }));
    assert.equal(await withingsPage.locator(".app-meta").textContent(), "Withings · Health");
    await page.waitForFunction(() => [...document.querySelectorAll(".app-info img")].every((img) => img.complete && img.naturalWidth > 0));
    await shot("apps-withings");

    // A device sign-in: the code to enter at OpenAI, until the person has.
    await page.goto(`${appUrl}/app/settings/apps/chatgpt`, { waitUntil: "networkidle" });
    const chatgpt = page.getByRole("region", { name: "ChatGPT" });
    await chatgpt.getByRole("button", { name: "Add account" }).click();
    await expect(chatgpt.getByLabel("Sign-in code").getByText("ABCD-1234"));
    assert.equal(await chatgpt.getByRole("link", { name: "Open OpenAI" }).getAttribute("href"), "https://auth.openai.com/codex/device");
    await shot("apps-chatgpt-code");
    await page.waitForFunction(() => true, null, { timeout: 100 });
    device.entered = true;
    await expect(chatgpt.getByText("Added ada@example.com."));
    assert.deepEqual(await chatgpt.locator(".connection-row strong").allTextContents(), ["ada@example.com"]);
    assert.equal(await chatgpt.getByLabel("Sign-in code").count(), 0);
    await shot("apps-chatgpt");

    // A Mac app: its accounts are the Macs, with no Add account, and what to set up on a Mac.
    await page.goto(`${appUrl}/app/settings/apps/onepassword`, { waitUntil: "networkidle" });
    const onepassword = page.getByRole("region", { name: "1Password" });
    await expect(onepassword.getByText("Your Macs are its accounts."));
    assert.deepEqual(await onepassword.locator(".connection-row strong").allTextContents(), ["browser_fixture_mac"]);
    assert.equal(await onepassword.getByRole("button", { name: "Add account" }).count(), 0);
    assert.equal(await onepassword.getByRole("button", { name: /^Remove/ }).count(), 0);
    await shot("apps-onepassword");

    // Where sign-ins used to come back still works: on the app's page.
    await page.goto(`${appUrl}/app/connections?signedIn=apps.gmail`, { waitUntil: "networkidle" });
    await expect(page.getByRole("region", { name: "Gmail" }).getByText("Account added."));
    assert.equal(new URL(page.url()).pathname, "/app/settings/apps/gmail");
    await page.getByRole("button", { name: "Close settings" }).click();

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
