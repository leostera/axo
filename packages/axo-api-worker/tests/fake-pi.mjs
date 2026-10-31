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
import { randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createServer } from "node:net";

const log = process.env.AXO_FAKE_PI_LOG;
const startupMs = Number(process.env.AXO_FAKE_PI_STARTUP_MS ?? "1500");
if (!log) throw new Error("AXO_FAKE_PI_LOG is required");

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
const reply = (prompt) => {
  const text = (words) => ({ message: { role: "assistant", content: [{ type: "text", text: words }] } });
  record({ type: "message", message: { role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() } });
  publish("message.end", { message: { role: "user", content: [{ type: "text", text: prompt }] } });
  publish("agent.start", {});
  publish("message.update", text("Running"));
  publish("message.update", text("x".repeat(70_000)));
  publish("message.update", text("Running the tests"));
  record({ type: "message", message: { ...text("Running the tests now.").message, timestamp: Date.now() } });
  publish("message.end", text("Running the tests now."));
  publish("agent.end", {});
};
// Raw, as Pi's terminal UI reads: keys arrive as typed (Enter as "\r"), and a lone Escape is not
// held back waiting for the end of a line.
if (process.stdin.isTTY) process.stdin.setRawMode(true);
process.stdin.on("data", (chunk) => {
  appendFileSync(log, ready ? chunk : `IGNORED:${chunk.toString("utf8")}`);
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
          appendFileSync(log, `SENT:${record.action.text}\n`);
          socket.write(`${JSON.stringify({ type: "commandResult", requestId: record.requestId, result: { accepted: true } })}\n`);
          if (!replied) {
            replied = true;
            reply(record.action.text);
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
  server.listen(process.env.AXO_PI_BRIDGE_SOCKET);
}, startupMs);
