import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { appendResultSchema } from "@axo/protocol";
import type { Peer } from "../testing/client";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, waitFor } from "./axod-support";
import { FakeTranscript, connectHost, pairHost, userMessage } from "./account-support";

async function append(daemon: Peer, transcript: FakeTranscript, from: number, header = false) {
  const reply = await daemon.call("axo.host.session.append", {
    sessionId: transcript.sessionId, epoch: 1, from,
    ...(header ? { header: transcript.transcript.header } : {}),
    records: transcript.records(from),
  });
  assert.ok("result" in reply, JSON.stringify(reply));
  assert.equal(appendResultSchema.parse(reply.result).outcome, "committed");
}

/** The file Pi wrote on the other Mac: its header, then every line. */
function piFile(transcript: FakeTranscript): string {
  return [transcript.transcript.header, ...transcript.records(1).map((record) => record.line)].map((line) => `${line}\n`).join("");
}

test("a paired Mac keeps a copy of another Mac's Session, as Pi wrote it, while it is written (RFD0022)", async (t) => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-axod-peers-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
  let daemon: ChildProcess | undefined;
  let studio: Peer | undefined;
  t.after(async () => {
    studio?.close();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  });

  daemon = spawn(resolve(process.cwd(), binary), [
    "--server-dir", serverDirectory, "--socket", socketPath, "--relay-url", api.url, "--host-credentials", "files",
  ], {
    stdio: "ignore",
    env: {
      ...process.env,
      HOME: root,
      AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
      AXO_PI_EXECUTABLE: fileURLToPath(new URL("../../../crates/axod/testdata/pi-fixture.sh", import.meta.url)),
    },
  });
  await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

  // The account has another Mac, the Studio, with a chat going.
  const account = await signIn(api);
  const studioHost = await pairHost(api, account, "Mac Studio");
  studio = await connectHost(api, account, studioHost);
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("Fix the relay backoff"), userMessage("and test it"));
  const synced = await studio.call("axo.host.sync", { hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced, JSON.stringify(synced));
  await append(studio, transcript, 1, true);

  // This Mac pairs; pairing is all it takes to follow the account.
  const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
  const { code } = (await pairing.json()) as { code: string };
  assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);
  const laptop = await waitFor("axod online", 20_000, async () =>
    (await listHosts(api.url, account)).find((host) => host.hostId !== studioHost.hostId && host.status === "online"), daemon);

  // Every Mac's transcripts are kept by host beside server/, the same way on every Mac.
  const sessions = join(root, "sessions");
  const copy = join(sessions, studioHost.hostId, "no-workspace", `${transcript.sessionId}.jsonl`);
  const read = async () => (existsSync(copy) ? await readFile(copy, "utf8") : undefined);
  await waitFor("the copy of the Studio's chat", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);

  // What the Studio writes next reaches the copy without asking.
  await transcript.write(userMessage("one more thing"));
  await append(studio, transcript, 3);
  await waitFor("the copy to follow", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);

  // The index lists the other Mac and its chat, never this Mac's own.
  const index = JSON.parse(await readFile(join(serverDirectory, "peers.json"), "utf8")) as {
    hosts: Array<{ hostId: string }>; sessions: Array<{ hostId: string; sessionId: string }>;
  };
  assert.deepEqual(index.hosts.map((host) => host.hostId), [studioHost.hostId]);
  assert.ok(index.sessions.every((session) => session.hostId !== laptop.hostId));
  assert.ok(index.sessions.some((session) => session.sessionId === transcript.sessionId));
  // Each host's folder says which Mac it is: the Studio's copies, and this Mac's own.
  const described = async (hostId: string) => JSON.parse(await readFile(join(sessions, hostId, "host.json"), "utf8")) as { hostId: string; label: string };
  assert.deepEqual(await described(studioHost.hostId), { hostId: studioHost.hostId, label: "Mac Studio" });
  assert.equal((await described(laptop.hostId)).hostId, laptop.hostId);
});
