#!/usr/bin/env node
// A stand-in for Pi in end-to-end tests: it binds to axod's Pi bridge the way the pi-axo
// extension does, and writes what it is typed or sent to $AXO_FAKE_PI_LOG.
//
// Like Pi, it is not ready at once. Pi ignores a submit until its startup has finished, and its
// bridge binds only after that. So until this fake has said hello, whatever it is typed is lost:
// it is logged as "IGNORED:" so a test that types too early sees it.
//
// A prompt comes as the bridge's `send` command. Once one is taken, it replies as Pi would over the bridge: the run starts, the reply
// grows (`message.update`, once with a payload too large to forward), the whole message ends,
// and the run ends. Like Pi, it records the conversation in its session file
// ($AXO_PI_SESSION_FILE) before it says so over the bridge: that file is what axod uploads.
//
// axod lets only a Session's own processes act as it (RFD0073), so a test reaches axod as this
// Pi's Session through it. With $AXO_FAKE_PI_AGENTS, from the moment it starts it serves, named
// by its Session (AXO_SESSION_ID, or AXO_REMOTE_SESSION_ID in a pane showing another Mac's):
//   <AXO_FAKE_PI_AGENTS>/<session>.sock      relays each connection to axod ($AXO_SOCKET);
//   <AXO_FAKE_PI_AGENTS>/<session>.mcp.sock  runs `$AXOD mcp` as this Pi's child, as Pi starts
//                                            its MCP server, wired to each connection.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { createConnection, createServer } from "node:net";

const log = process.env.AXO_FAKE_PI_LOG;
const startupMs = Number(process.env.AXO_FAKE_PI_STARTUP_MS ?? "1500");
/** What it was typed or sent, for a test that reads $AXO_FAKE_PI_LOG. */
const note = (text) => { if (log) appendFileSync(log, text); };

const agents = process.env.AXO_FAKE_PI_AGENTS;
const session = process.env.AXO_SESSION_ID ?? process.env.AXO_REMOTE_SESSION_ID;
if (agents && session) {
  const serve = (name, connected) => {
    const path = join(agents, name);
    rmSync(path, { force: true });
    createServer(connected).listen(path);
  };
  serve(`${session}.sock`, (client) => {
    const upstream = createConnection(process.env.AXO_SOCKET);
    client.pipe(upstream).pipe(client);
    client.on("error", () => upstream.destroy());
    upstream.on("error", () => client.destroy());
  });
  serve(`${session}.mcp.sock`, (client) => {
    const mcp = spawn(process.env.AXOD, ["mcp"], { stdio: ["pipe", "pipe", "ignore"] });
    client.pipe(mcp.stdin);
    mcp.stdout.pipe(client);
    client.on("error", () => mcp.kill());
    client.on("close", () => mcp.kill());
    mcp.on("exit", () => client.end());
  });
}

let ready = false;
let bridge;
let sequence = 0;
const streamId = randomUUID();
let replied = false;
const publish = (name, data) => {
  sequence += 1;
  bridge?.write(`${JSON.stringify({ type: "event", streamId, sequence, name, data })}\n`);
};
const piSessionId = randomUUID();
let lastEntry = null;
/** Appends an entry to the session file, starting it with its header as Pi does. */
const record = (entry) => {
  const file = process.env.AXO_PI_SESSION_FILE;
  if (!file) return;
  if (!existsSync(file)) {
    mkdirSync(dirname(file), { recursive: true });
    appendFileSync(file, `${JSON.stringify({ type: "session", version: 3, id: piSessionId, timestamp: new Date().toISOString(), cwd: process.env.PWD })}\n`);
  }
  const id = randomUUID().slice(0, 8);
  appendFileSync(file, `${JSON.stringify({ ...entry, id, parentId: lastEntry, timestamp: new Date().toISOString() })}\n`);
  lastEntry = id;
};
// A reply grows over time, as Pi's does: progress is the relay's lossy class, and updates sent
// all at once may be dropped behind the oversized one, which no client could then see grow.
const pause = () => new Promise((resume) => setTimeout(resume, 150));
const reply = async (prompt) => {
  const text = (words) => ({ message: { role: "assistant", content: [{ type: "text", text: words }] } });
  record({ type: "message", message: { role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() } });
  publish("message.end", { message: { role: "user", content: [{ type: "text", text: prompt }] } });
  publish("agent.start", {});
  publish("message.update", text("Running"));
  await pause();
  publish("message.update", text("x".repeat(70_000)));
  await pause();
  publish("message.update", text("Running the tests"));
  await pause();
  record({ type: "message", message: { ...text("Running the tests now.").message, timestamp: Date.now() } });
  publish("message.end", text("Running the tests now."));
  publish("agent.end", {});
};
// Raw, as Pi's terminal UI reads: keys arrive as typed (Enter as "\r"), and a lone Escape is not
// held back waiting for the end of a line.
if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdin.on("data", (chunk) => {
  note(ready ? chunk : `IGNORED:${chunk.toString("utf8")}`);
});

setTimeout(() => {
  const identity = {
    axoSessionId: process.env.AXO_SESSION_ID,
    axoPaneId: process.env.AXO_PANE_ID,
    piSessionId,
    sessionFile: process.env.AXO_PI_SESSION_FILE,
    cwd: process.env.PWD,
    processId: process.pid,
  };
  const server = createServer((socket) => {
    let buffer = "";
    socket.on("data", (data) => {
      buffer += data.toString("utf8");
      let newline;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const record = JSON.parse(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        if (record.type === "command" && record.action?.kind === "send" && socket === bridge) {
          note(`SENT:${record.action.text}\n`);
          // A prompt's attachments (RFD0030): where axod put each file.
          if (record.action.attachments) note(`ATTACHED:${JSON.stringify(record.action.attachments)}\n`);
          socket.write(`${JSON.stringify({ type: "commandResult", requestId: record.requestId, result: { accepted: true } })}\n`);
          if (!replied) {
            replied = true;
            void reply(record.action.text);
          }
          continue;
        }
        if (record.type === "authenticate" && record.token === process.env.AXO_PI_BRIDGE_TOKEN) {
          ready = true;
          bridge = socket;
          socket.write(`${JSON.stringify({ type: "authenticated", protocolVersion: 1 })}\n`);
          socket.write(`${JSON.stringify({ type: "hello", protocolVersion: 1, identity })}\n`);
        }
      }
    });
    socket.on("error", () => {});
  });
  // A pane showing another Mac's Session has no bridge.
  if (process.env.AXO_PI_BRIDGE_SOCKET) server.listen(process.env.AXO_PI_BRIDGE_SOCKET);
}, startupMs);
