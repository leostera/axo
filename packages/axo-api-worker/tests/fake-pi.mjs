#!/usr/bin/env node
// A stand-in for Pi in end-to-end tests: it binds to axod's Pi bridge the way the pi-axo
// extension does, and writes what is typed into it to $AXO_FAKE_PI_LOG.
//
// Like Pi, it is not ready at once. Pi ignores a submit until its startup has finished, and its
// bridge binds only after that. So until this fake has said hello, whatever it is typed is lost:
// it is logged as "IGNORED:" so a test that types too early sees it.
import { randomUUID } from "node:crypto";
import { appendFileSync } from "node:fs";
import { createServer } from "node:net";

const log = process.env.AXO_FAKE_PI_LOG;
const startupMs = Number(process.env.AXO_FAKE_PI_STARTUP_MS ?? "1500");
if (!log) throw new Error("AXO_FAKE_PI_LOG is required");

let ready = false;
process.stdin.on("data", (chunk) => {
  appendFileSync(log, ready ? chunk : `IGNORED:${chunk.toString("utf8")}`);
});

setTimeout(() => {
  const identity = {
    axoSessionId: process.env.AXO_SESSION_ID,
    axoPaneId: process.env.AXO_PANE_ID,
    piSessionId: randomUUID(),
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
        if (record.type === "authenticate" && record.token === process.env.AXO_PI_BRIDGE_TOKEN) {
          ready = true;
          socket.write(`${JSON.stringify({ type: "authenticated", protocolVersion: 1 })}\n`);
          socket.write(`${JSON.stringify({ type: "hello", protocolVersion: 1, identity })}\n`);
        }
      }
    });
    socket.on("error", () => {});
  });
  server.listen(process.env.AXO_PI_BRIDGE_SOCKET);
}, startupMs);
