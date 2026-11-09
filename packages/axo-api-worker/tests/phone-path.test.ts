import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { harness, signInNative } from "./harness";
import { listHosts, localCall, terminate, TestAccountClient, waitFor } from "./axod-support";

/**
 * What the phone does, end to end, with nothing faked but the sign-in provider: a bearer token
 * (no cookie, no Origin), a real Worker, and a real axod whose Pi is a stand-in that records what
 * is typed into it.
 *
 *   phone ──WSS──▶ ClientDO ──▶ HostDO ◀──WSS── axod (dials out, so no inbound port)
 *                     └──▶ SessionDO ◀── axod's uploads
 *
 * axod never listens for the cloud: it opens one WebSocket to its HostDO, which sends a client's
 * `axo.remote.*` commands down that same socket. Pi's session file goes up the same socket, line
 * by line, and the phone reads it back from the cloud (RFD0018).
 */
test("a phone signed in with a token starts a chat on the Mac and prompts its Pi", async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-phone-path-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  const typedIntoPi = join(root, "pi-typed.log");
  // Like Pi, it takes a prompt only once it has started and bound its bridge; what it is typed
  // before then is logged as ignored.
  const pi = join(dirname(fileURLToPath(import.meta.url)), "fake-pi.mjs");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });

  let daemon: ChildProcess | undefined;
  let client: TestAccountClient | undefined;
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory,
      "--socket", socketPath,
      "--relay-url", api.url,
      "--host-credentials", "files",
    ], { stdio: "ignore", env: {
      ...process.env, HOME: root, AXO_PI_EXECUTABLE: pi, AXO_FAKE_PI_LOG: typedIntoPi,
      AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
    } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    // The phone's sign-in: PKCE through the system browser, then a bearer token.
    const phone = await signInNative(api);
    assert.deepEqual(Object.keys(phone.headers), ["Authorization"], "the phone sends only a token");
    // Pairing is by a person on the Mac, but the account is the phone's.
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: phone.headers });
    assert.equal(pairing.status, 200, "a token can create a pairing code");
    const { code } = (await pairing.json()) as { code: string };
    assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);

    const host = await waitFor("the Mac coming online for the phone's account", 20_000, async () =>
      (await listHosts(api.url, phone)).find((candidate) => candidate.status === "online"), daemon);
    const target = { hostId: host.hostId, hostGeneration: host.hostGeneration };

    client = await TestAccountClient.connect(api.url, phone);
    assert.deepEqual(client.hosts.map((listed) => [listed.hostId, listed.online]), [[host.hostId, true]]);
    const command = client.connection.command.bind(client.connection);

    // A chat is a Session with a folder; a new one beside another starts Pi in the same folder.
    const projectDirectory = join(root, "project");
    await mkdir(projectDirectory);
    const local = await localCall(socketPath, "axo.session.create", { folder: projectDirectory }) as { id: string };
    const { session } = await command("axo.remote.session.create", { target, like: local.id });
    assert.equal(session.folderName, "project", "the phone sees the folder's name, not its path");
    assert.equal(session.hostId, host.hostId);
    assert.equal(session.hasAgent, true, "a chat is a Session with a Pi");
    const listed = await waitFor("the new chat in the phone's list", 15_000, async () => client!.sessions.get(session.sessionId), daemon);
    assert.equal(listed.metadata.folderName, "project");
    assert.equal(listed.metadata.hasAgent, true);
    await client.open(host.hostId, session.sessionId);

    // Say something to its Pi at once, while it is still starting, as a chat's first message
    // does. It waits for Pi's bridge and then arrives over it.
    const accepted = await command("axo.remote.session.prompt", { target, sessionId: session.sessionId, text: "please run the tests" });
    assert.equal(accepted.accepted, true);
    const typed = await waitFor("the prompt reaching Pi", 15_000, async () => {
      const text = await readFile(typedIntoPi, "utf8").catch(() => "");
      return text.includes("please run the tests") ? text : undefined;
    }, daemon);
    assert.equal(typed, "SENT:please run the tests\n");

    // The reply shows as it grows, in the Session's "message" progress slot.
    const replies = () => client!.progress.flatMap(({ sessionId, slot, snapshot }) => {
      const text = (snapshot as { message?: { content?: Array<{ text?: string }> } } | null)?.message?.content?.[0]?.text;
      return sessionId === session.sessionId && slot === "message" && text ? [text] : [];
    });
    await waitFor("Pi's reply growing on the phone", 15_000, async () => replies().includes("Running the tests") ? true : undefined, daemon);

    // What was said is what Pi wrote to its session file, uploaded by axod and read back from
    // the cloud: not how it grew.
    const entries = await waitFor("the conversation in the cloud", 20_000, async () => {
      const entries = client!.entries(session.sessionId);
      return entries.filter((entry) => entry.type === "message").length >= 2 ? entries : undefined;
    }, daemon);
    assert.deepEqual(entries.map((entry) => [entry.message?.role, (entry.message?.content as Array<{ text: string }>)[0]!.text]), [
      ["user", "please run the tests"],
      ["assistant", "Running the tests now."],
    ]);
    // A client that comes later reads the same records.
    const later = await TestAccountClient.connect(api.url, phone);
    const reread = await later.open(host.hostId, session.sessionId);
    assert.deepEqual(reread.records.map((record) => record.line), client.records.get(session.sessionId)!.map((record) => record.line));
    later.close();

    // Stopping a reply, or answering Pi's question, is a key pressed in Pi's pane.
    const pressed = await command("axo.remote.session.key", { target, sessionId: session.sessionId, key: "escape" });
    assert.equal(pressed.accepted, true);
    await waitFor("Escape reaching Pi", 10_000, async () =>
      (await readFile(typedIntoPi, "utf8").catch(() => "")).endsWith("\u001b") ? true : undefined, daemon);
  } finally {
    client?.close();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
