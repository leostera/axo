import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { type HostEvent } from "@axo/app";
import { harness, signInNative } from "./harness";
import { accountApi, localCall, terminate, waitFor, waitForHostEvent } from "./axod-support";

/**
 * What the phone does, end to end, with nothing faked but the sign-in provider: a bearer token
 * (no cookie, no Origin), a real Worker, and a real axod whose Pi is a stand-in that records what
 * is typed into it.
 *
 *   phone ──HTTPS/WSS──▶ Worker (AxoAccountManager) ◀──WSS── axod (dials out, so no inbound port)
 *
 * axod never listens for the cloud: it opens one WebSocket to the Worker and the Worker sends a
 * client's `axo.remote.*` requests down that same socket; axod answers on it.
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
  let client: Awaited<ReturnType<ReturnType<typeof accountApi>["connectHost"]>> | undefined;
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory,
      "--socket", socketPath,
      "--relay-url", api.url,
      "--host-credentials", "files",
    ], { stdio: "ignore", env: { ...process.env, HOME: root, AXO_PI_EXECUTABLE: pi, AXO_FAKE_PI_LOG: typedIntoPi } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    // The phone's sign-in: PKCE through the system browser, then a bearer token.
    const phone = await signInNative(api);
    assert.deepEqual(Object.keys(phone.headers), ["Authorization"], "the phone sends only a token");
    const phoneApi = accountApi(api.url, phone);

    // Pairing is by a person on the Mac, but the account is the phone's.
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: phone.headers });
    assert.equal(pairing.status, 200, "a token can create a pairing code");
    const { code } = (await pairing.json()) as { code: string };
    assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);

    const host = await waitFor("the Mac coming online for the phone's account", 20_000, async () =>
      (await phoneApi.listHosts()).find((candidate) => candidate.status === "online"), daemon);
    const target = { hostId: host.hostId, hostGeneration: host.hostGeneration };

    const events: HostEvent[] = [];
    client = await phoneApi.connectHost(target, (event) => events.push(event));
    await waitForHostEvent(events, (event) => event.type === "host.presence" && event.status === "online",
      "the phone's subscription", daemon);

    // A plain Session is a bare terminal with no Pi: not a chat. This is what the phone's first
    // "Chat" button made, and why nothing could be said to it.
    const plain = await client.call("axo.remote.session.create", { target });
    assert.equal(plain.session.hasAgent, false, "axo.remote.session.create makes a terminal, not a chat");

    // A chat is a Session in a Workspace, which starts Pi in the Workspace's directory.
    const workspaceDirectory = join(root, "project");
    await mkdir(workspaceDirectory);
    await localCall(socketPath, "axo.workspace.create", { name: "Project", directoryPath: workspaceDirectory });
    const { workspaces } = await client.call("axo.remote.workspace.list", { target });
    assert.deepEqual(workspaces.map((workspace) => workspace.name), ["Project"], "the phone sees names, not paths");
    const { session } = await client.call("axo.remote.workspace.session.create", {
      target, workspaceId: workspaces[0]!.workspaceId,
    });
    assert.equal(session.hostId, host.hostId);
    assert.equal(session.hasAgent, true, "a chat is a Session with a Pi");
    await waitFor("the new chat in the phone's list", 8_000, async () =>
      (await phoneApi.listHostSessions(target)).some((candidate) => candidate.sessionId === session.sessionId) ? true : undefined,
      daemon);

    // Say something to its Pi at once, while it is still starting, as a chat's first message
    // does. It waits for Pi and then arrives as one bracketed paste and a submit.
    const accepted = await client.call("axo.remote.session.prompt", {
      target, sessionId: session.sessionId, text: "please run the tests",
    });
    assert.equal(accepted.accepted, true);
    const typed = await waitFor("the prompt reaching Pi", 15_000, async () => {
      const text = await readFile(typedIntoPi, "utf8").catch(() => "");
      return text.includes("please run the tests") ? text : undefined;
    }, daemon);
    assert.equal(typed, "\u001b[200~please run the tests\u001b[201~\n");
  } finally {
    client?.close?.();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
