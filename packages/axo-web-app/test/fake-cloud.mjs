// A cloud with one Mac, and the app served by Vite against it, for the browser tests that drive
// what the Mac sends: the conversation's rendering (RFD0040) and its tools.
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { realpathSync } from "node:fs";
import { once } from "node:events";
import { resolve } from "node:path";
import react from "@vitejs/plugin-react";
import { chromium } from "playwright-core";
import { WebSocketServer } from "ws";
import { createServer as createViteServer } from "vite";

export const hostId = "1e1e7f91-3d8f-4f97-8f71-4fc7d53313c6";
export const now = "2026-10-16T12:00:00.000Z";
const siteRoot = resolve(import.meta.dirname, "../../../sites/axo.leostera.dev");
export const chromePath = process.env.CHROME_PATH ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
export const sid = (n) => `${n.toString(16).padStart(8, "0")}-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
export const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
/** A one-pixel PNG, base64. */
export const PIXEL = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

/** Pi's line at `cursor`: a message entry. */
export function record(cursor, message) {
  const entry = { type: "message", id: `entry-${cursor}`, parentId: cursor > 1 ? `entry-${cursor - 1}` : null, timestamp: now, message };
  return { cursor, id: entry.id, format: "pi/3", hash: `sha256:${cursor.toString(16).padStart(64, "0")}`, line: JSON.stringify(entry) };
}

export function listed(sessionId, name, head) {
  return {
    hostId, sessionId, epoch: 1, head, status: "ready",
    metadata: { name, emoji: null, folderName: null, hasAgent: true, createdAt: null, lastMessageAt: Math.floor(Date.now() / 1000) - 60, archived: false },
  };
}

export async function freePort() {
  const server = createNetServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address();
  await new Promise((done) => server.close(done));
  return port;
}

/**
 * A cloud with one Mac, whose socket the test drives: `transcripts` holds each chat's records, by
 * Session id, and `sessions` what the sidebar lists (see `listed`).
 */
export async function startCloud(transcripts, sessions, { models = [], hosts } = {}) {
  const listedHosts = hosts ?? [{ hostId, hostGeneration: "f9c5761c-3b2d-42a8-bb19-9a8c0b8cf230", label: "Mac", hostKind: "macos", online: true, lastSeenAt: now }];
  const modelSets = [];
  const prompts = [];
  let rejectNextModel = false;
  const sockets = new Set();
  let paused = false;
  const pending = [];
  const http = createHttpServer((request, response) => {
    response.setHeader("Content-Type", "application/json");
    if (request.url?.startsWith("/api/v1/account/apps")) return response.end(JSON.stringify({ apps: [] }));
    // Every asset is the same one-pixel picture.
    if (request.url?.startsWith("/api/v1/account/assets/")) {
      response.setHeader("Content-Type", "image/png");
      return response.end(Buffer.from(PIXEL, "base64"));
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not here" }));
  });
  const requests = new Map();
  const answers = [];
  let holdAnswers = false;
  const answerReplies = [];
  const wss = new WebSocketServer({ noServer: true });
  http.on("upgrade", (request, socket, head) => wss.handleUpgrade(request, socket, head, (ws) => wss.emit("connection", ws)));
  wss.on("connection", (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("message", (raw) => {
      const call = JSON.parse(raw.toString());
      if (!call.method || call.id === undefined) return;
      const reply = (result) => {
        const send = () => { if (socket.readyState === 1) socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, result })); };
        if (paused) pending.push(send); else send();
      };
      if (call.method === "axo.client.hello" && call.params.protocolVersion !== 2) {
        return socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32602, message: "Invalid params" } }));
      }
      if (call.method === "axo.client.hello" || call.method === "axo.client.refresh") {
        reply({ hosts: listedHosts, sessions });
        for (const elicitation of requests.values()) socket.send(JSON.stringify({ jsonrpc: "2.0", method: "axo.elicitation.requested", params: { hostId, elicitation } }));
        return;
      }
      if (call.method === "axo.client.command") {
        const { method, params } = call.params;
        call.method = method;
        call.params = params;
      }
      if (call.method === "axo.elicitation.resolve") {
        answers.push(call.params);
        const question = requests.get(call.params.elicitationId);
        if (!question) return socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32011, message: "Already answered" } }));
        requests.delete(question.id);
        send("axo.elicitation.resolved", { hostId, id: question.id, sessionId: question.sessionId, action: call.params.action });
        const done = () => reply({ resolved: true });
        if (holdAnswers) answerReplies.push(done); else done();
        return;
      }
      if (call.method === "axo.remote.session.models") return reply({ models });
      if (call.method === "axo.remote.session.model.set") {
        modelSets.push(call.params);
        if (rejectNextModel) {
          rejectNextModel = false;
          return socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32007, message: "provider needs sign-in" } }));
        }
        const index = sessions.findIndex(session => session.sessionId === call.params.sessionId);
        const pi = sessions[index].metadata.pi;
        const selected = call.params.model ? models.find(model => model.provider === call.params.model.provider && model.id === call.params.model.id) : null;
        const model = selected ? { provider: selected.provider, id: selected.id, name: selected.name } : pi.model;
        const levels = selected?.thinkingLevels ?? models.find(item => item.provider === model.provider && item.id === model.id)?.thinkingLevels ?? [];
        const thinkingLevel = call.params.thinkingLevel ?? (levels.includes(pi.thinkingLevel) ? pi.thinkingLevel : levels[0] ?? "off");
        sessions[index] = { ...sessions[index], metadata: { ...sessions[index].metadata, pi: { model, thinkingLevel } } };
        reply({ saved: true });
        send("axo.client.sessions", { hostId, sessions: [sessions[index]] });
        return;
      }
      if (call.method === "axo.remote.session.prompt") {
        prompts.push(call.params);
        return reply({ accepted: true });
      }
      if (call.method === "axo.client.session.open") {
        http.emit("session-open", call.params);
        const lines = transcripts.get(call.params.sessionId) ?? [];
        const records = call.params.have ? lines.filter((line) => line.cursor > call.params.have.cursor) : lines.slice(-call.params.window.last);
        return reply({ epoch: 1, records, cursor: lines.length, older: null, progress: [] });
      }
      socket.send(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "unknown method" } }));
    });
  });
  const send = (method, params) => { for (const socket of sockets) socket.send(JSON.stringify({ jsonrpc: "2.0", method, params })); };
  return {
    http, wss, modelSets, prompts, answers,
    holdAnswers() { holdAnswers = true; },
    releaseAnswers() { holdAnswers = false; for (const reply of answerReplies.splice(0)) reply(); },
    ask(elicitation) { requests.set(elicitation.id, elicitation); send("axo.elicitation.requested", { hostId, elicitation }); },
    settle(id, action = "cancel") {
      const question = requests.get(id);
      if (!question) return;
      requests.delete(id);
      send("axo.elicitation.resolved", { hostId, id, sessionId: question.sessionId, action });
    },
    rejectNextModelChange() { rejectNextModel = true; },
    activity(sessionId, lastMessageAt) {
      const index = sessions.findIndex(session => session.sessionId === sessionId);
      sessions[index] = { ...sessions[index], metadata: { ...sessions[index].metadata, lastMessageAt } };
      send("axo.client.sessions", { hostId, sessions: [sessions[index]] });
    },
    pause() { paused = true; },
    resume() { paused = false; for (const reply of pending.splice(0)) reply(); },
    /** Writes a line of `sessionId`, as Pi would. */
    write(sessionId, message) {
      const lines = transcripts.get(sessionId);
      const next = record(lines.length + 1, message);
      lines.push(next);
      send("axo.client.session.records", { sessionId, epoch: 1, records: [next], cursor: next.cursor });
    },
    /** Queue/receipt records from another client, without sending a prompt from this browser. */
    custom(sessionId, customType, data) {
      const lines = transcripts.get(sessionId);
      const next = record(lines.length + 1, null);
      const { message: _, ...entry } = JSON.parse(next.line);
      next.line = JSON.stringify({ ...entry, type: "custom", customType, data });
      lines.push(next);
      send("axo.client.session.records", { sessionId, epoch: 1, records: [next], cursor: next.cursor });
    },
    progress(sessionId, snapshot) { send("axo.client.session.progress", { sessionId, slot: "message", snapshot }); },
    /** A running tool's output so far, as Pi sends it: by its call id. */
    toolProgress(sessionId, callId, snapshot) { send("axo.client.session.progress", { sessionId, slot: callId, snapshot }); },
    status(sessionId, status) {
      const index = sessions.findIndex((session) => session.sessionId === sessionId);
      sessions[index] = { ...sessions[index], status };
      send("axo.client.sessions", { hostId, sessions: [sessions[index]] });
    },
  };
}

/** The app, served by Vite from the site, its API the cloud's; and Chrome. */
export async function startApp(cloud) {
  cloud.http.listen(0, "127.0.0.1");
  await once(cloud.http, "listening");
  const apiPort = cloud.http.address().port;
    const appPort = await freePort();
  const appUrl = `http://127.0.0.1:${appPort}`;
  const vite = await createViteServer({
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
  const browser = await chromium.launch({ executablePath: chromePath, headless: true, args: ["--no-sandbox", "--disable-dev-shm-usage"] });
  return {
    appUrl, browser,
    async close() {
      await browser.close();
      await vite.close();
      cloud.wss.close();
      cloud.http.close();
    },
  };
}
