import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";
import { test, type TestContext } from "node:test";
import { SYNC, appendResultSchema } from "@axo/protocol";
import type { Peer } from "../testing/client";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, waitFor } from "./axod-support";
import { FakeTranscript, assistantMessage, connectClient, connectHost, pairHost, userMessage } from "./account-support";

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

/** A real axod on a scratch home, against the Worker; stopped when the test ends. */
async function startAxod(t: TestContext, configuration: { entry?: string } = {}) {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const api = await harness(configuration);
  // Resolved: a Session's folder must be inside its Workspace, as macOS names both.
  const root = await realpath(await mkdtemp(join(tmpdir(), "axo-axod-peers-")));
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
  return { api, root, serverDirectory, socketPath, daemon, log: () => readFile(join(serverDirectory, "stderr.log"), "utf8").catch(() => ""), setStudio: (peer: Peer) => { studio = peer; } };
}

/** Pairs the axod with the account: pairing is all it takes (RFD0022). */
async function link(api: Awaited<ReturnType<typeof harness>>, account: Awaited<ReturnType<typeof signIn>>, socketPath: string) {
  const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: account.headers });
  const { code } = (await pairing.json()) as { code: string };
  assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);
}

test("a paired Mac keeps a copy of another Mac's Session, as Pi wrote it, while it is written (RFD0022)", async (t) => {
  const { api, root, serverDirectory, socketPath, daemon, log, setStudio } = await startAxod(t);

  // The account has another Mac, the Studio, with a chat going.
  const account = await signIn(api);
  const studioHost = await pairHost(api, account, "Mac Studio");
  const studio = await connectHost(api, account, studioHost);
  setStudio(studio);
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("Fix the relay backoff"), userMessage("and test it"));
  const synced = await studio.call("axo.host.sync", { hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced, JSON.stringify(synced));
  await append(studio, transcript, 1, true);

  // This Mac pairs; pairing is all it takes to follow the account.
  await link(api, account, socketPath);
  const laptop = await waitFor("axod online", 20_000, async () =>
    (await listHosts(api.url, account)).find((host) => host.hostId !== studioHost.hostId && host.status === "online"), daemon);

  // Every Mac's transcripts are kept by host beside server/, the same way on every Mac.
  const sessions = join(root, "sessions");
  const copy = join(sessions, studioHost.hostId, "no-workspace", `${transcript.sessionId}.jsonl`);
  const read = async () => (existsSync(copy) ? await readFile(copy, "utf8") : undefined);
  await waitFor("the copy of the Studio's chat", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);

  // It follows the Studio on the Studio's HostDO, not through the account (RFD0032, protocol 3).
  await waitFor("axod on protocol 3", 20_000, async () => ((await log()).includes("event=peers.direct_ready hosts=1") ? true : undefined), daemon);
  assert.ok(!(await log()).includes("event=peers.protocol_fallback"), await log());

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

  // Archived, the chat stays in the cloud: the copy goes.
  const archived = await studio.call("axo.host.sync", {
    hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration, round: 2,
    sessions: [transcript.manifestRow(2, { archived: true })],
  });
  assert.ok("result" in archived, JSON.stringify(archived));
  await waitFor("the archived chat's copy to go", 20_000, async () => (existsSync(copy) ? undefined : true), daemon);

  // A pane on it fetches it again, and closing the pane lets it go.
  await localCall(socketPath, "axo.peer.session.open", { hostId: studioHost.hostId, sessionId: transcript.sessionId });
  await waitFor("the copy fetched for the pane", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);
  await localCall(socketPath, "axo.peer.session.close", { hostId: studioHost.hostId, sessionId: transcript.sessionId });
  await waitFor("the copy to go with the pane", 20_000, async () => (existsSync(copy) ? undefined : true), daemon);
});

test("this Mac's archived Session is deleted once the cloud holds it whole, and reopening it fetches it back (RFD0027)", async (t) => {
  const { api, socketPath, daemon } = await startAxod(t);
  const account = await signIn(api);
  await link(api, account, socketPath);

  // A Session with a conversation longer than one batch, uploaded as Pi writes it.
  const created = (await localCall(socketPath, "axo.session.create")) as { id: string; piSessionFile: string };
  const file = created.piSessionFile;
  const transcript = await FakeTranscript.create(created.id);
  for (let turn = 0; turn < 50; turn += 1) await transcript.write(userMessage(`Fix the relay backoff, take ${turn}`), assistantMessage("Done, and tested."));
  const records = transcript.transcript.count;
  assert.ok(records > SYNC.clientRecords);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, piFile(transcript));
  const original = piFile(transcript);
  const cloudCount = async () => {
    const { client, hello } = await connectClient(api, account);
    client.close();
    return hello.sessions.find((session) => session.sessionId === created.id)?.head;
  };
  await waitFor("the upload", 20_000, async () => ((await cloudCount()) === records ? true : undefined), daemon);

  // Archived, and held by the cloud whole: the file goes.
  await localCall(socketPath, "axo.session.close", { sessionId: created.id });
  await waitFor("the archived transcript to go", 20_000, async () => (existsSync(file) ? undefined : true), daemon);
  assert.equal(await cloudCount(), records, "the cloud keeps it all");

  // Reopening it puts it back as it was, before Pi starts.
  const reopened = (await localCall(socketPath, "axo.session.reopen")) as { id: string };
  assert.equal(reopened.id, created.id);
  assert.equal(await readFile(file, "utf8"), original);

  // Open again, it is read and uploaded as before: a new line reaches the cloud.
  await transcript.write(userMessage("one more thing"));
  await writeFile(file, piFile(transcript));
  await waitFor("the next line", 20_000, async () => ((await cloudCount()) === records + 1 ? true : undefined), daemon);
});

test("a Mac follows over protocol 2 while the cloud can't serve it a Mac's HostDO (RFD0032)", async (t) => {
  const entry = fileURLToPath(new URL("./fixtures/without-peer-route.ts", import.meta.url));
  const { api, root, socketPath, daemon, log, setStudio } = await startAxod(t, { entry });
  const account = await signIn(api);
  const studioHost = await pairHost(api, account, "Mac Studio");
  const studio = await connectHost(api, account, studioHost);
  setStudio(studio);
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("Fix the relay backoff"));
  const synced = await studio.call("axo.host.sync", { hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced, JSON.stringify(synced));
  await append(studio, transcript, 1, true);

  await link(api, account, socketPath);
  const copy = join(root, "sessions", studioHost.hostId, "no-workspace", `${transcript.sessionId}.jsonl`);
  const read = async () => (existsSync(copy) ? await readFile(copy, "utf8") : undefined);
  // The Studio's HostDO refuses it, so it says so and keeps the copy through the account.
  await waitFor("the fallback to protocol 2", 20_000, async () => ((await log()).includes("event=peers.protocol_fallback") ? true : undefined), daemon);
  await waitFor("the copy over protocol 2", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);
  await transcript.write(userMessage("one more thing"));
  await append(studio, transcript, 2);
  await waitFor("the copy to follow", 20_000, async () => ((await read()) === piFile(transcript) ? true : undefined), daemon);
  assert.ok(!(await log()).includes("event=peers.direct_ready"));
});

test("a Mac's command reaches the Mac it names through that Mac's HostDO, and the answer comes back (RFD0024, RFD0032)", async (t) => {
  const { api, socketPath, daemon, log, setStudio } = await startAxod(t);
  const account = await signIn(api);
  const studioHost = await pairHost(api, account, "Mac Studio");
  const studio = await connectHost(api, account, studioHost);
  setStudio(studio);
  const transcript = await FakeTranscript.create();
  await transcript.write(userMessage("Fix the relay backoff"));
  const synced = await studio.call("axo.host.sync", { hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration, round: 1, sessions: [transcript.manifestRow()] });
  assert.ok("result" in synced, JSON.stringify(synced));
  await append(studio, transcript, 1, true);
  await link(api, account, socketPath);
  await waitFor("axod on protocol 3", 20_000, async () => ((await log()).includes("event=peers.direct_ready hosts=1") ? true : undefined), daemon);

  const params = { sessionId: transcript.sessionId, text: "and test it" };
  const prompt = localCall(socketPath, "axo.peer.command", { hostId: studioHost.hostId, method: "axo.remote.session.prompt", params });
  let forwarded: { id: string; method: string; params: unknown } | undefined;
  while (forwarded?.method !== "axo.remote.session.prompt") forwarded = (await studio.next()) as typeof forwarded;
  assert.deepEqual(forwarded.params, { ...params, target: { hostId: studioHost.hostId, hostGeneration: studioHost.hostGeneration } });
  studio.send({ jsonrpc: "2.0", id: forwarded.id, result: { accepted: true } });
  assert.deepEqual(await prompt, { accepted: true });
});
