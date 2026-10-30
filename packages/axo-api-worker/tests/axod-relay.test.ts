import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { RemoteAxoApi, type HostEvent, type WebSocketLike } from "@axo/app";
import WebSocket from "ws";
import { createConnection } from "node:net";
import { harness, signIn } from "./harness";
import { accountApi, localCall, sleep, terminate, waitFor, waitForHostEvent } from "./axod-support";

test("an isolated axod pairs with an account, then the account drives it through the relay until revoked", async (t) => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-axod-relay-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });

  let daemon: ChildProcess | undefined;
  let attachment: ChildProcess | undefined;
  let client: Awaited<ReturnType<RemoteAxoApi["connectHost"]>> | undefined;
  const liveEvents: HostEvent[] = [];
  const outputChunks: string[] = [];
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory,
      "--socket", socketPath,
      // A loopback relay may use plain HTTP; remote relays must use TLS.
      "--relay-url", api.url,
      // Never touch the login Keychain from a test.
      "--host-credentials", "files",
    ], {
      stdio: "ignore",
      // Pi panes run the inert fixtures, never the developer's Pi; without an extension axod
      // starts no Home Session and registers none.
      env: {
        ...process.env,
        HOME: root,
        AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
        AXO_PI_EXECUTABLE: fileURLToPath(new URL("../../../crates/axod/testdata/pi-fixture.sh", import.meta.url)),
      },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      daemon!.once("spawn", () => resolveSpawn());
      daemon!.once("error", rejectSpawn);
    });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    // A signed-in person creates a pairing code; this Mac redeems it locally.
    const account = await signIn(api);
    const remoteApi = accountApi(api.url, account);
    assert.deepEqual(await remoteApi.listHosts(), [], "an unpaired host is not visible to anyone");
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), {
      method: "POST",
      headers: account.headers,
    });
    assert.equal(pairing.status, 200);
    const { code } = (await pairing.json()) as { code: string };
    const linked = (await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean };
    assert.equal(linked.linked, true);

    // The link lives in axod's database; the secret is a private file, never in the database.
    const credentialFiles = await readdir(join(serverDirectory, "host-credentials"));
    assert.equal(credentialFiles.length, 1);
    const credentialFile = join(serverDirectory, "host-credentials", credentialFiles[0]!);
    assert.equal((await stat(credentialFile)).mode & 0o777, 0o600);
    const database = await readFile(join(serverDirectory, "axo.db"));
    assert.equal(database.includes(await readFile(credentialFile)), false);
    assert.equal(existsSync(join(serverDirectory, "relay.json")), false);

    const replay = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "GET", headers: account.headers });
    assert.notEqual(replay.status, 200, "pairing codes are created only by POST");

    const registered = await waitFor("axod host registration", 20_000, async () =>
      (await remoteApi.listHosts()).find((host) => host.status === "online"),
    daemon);
    assert.equal(registered.stale, false);
    const { hostId, hostGeneration } = registered;
    assert.ok(registered.sessions.length > 0, "axod must register its initial local session");
    const firstSession = registered.sessions[0];
    assert.ok(firstSession.shells.length > 0, "registered session has a shell");
    assert.equal(JSON.stringify(firstSession).match(/attachSocketPath|ptyDevice|terminalOutput/gi), null);

    // A conversation redacted on this Mac is published through axod's relay link, under the
    // host's account: the Mac holds no Cloudflare credentials.
    const snapshot = {
      version: 1,
      title: "Relay share",
      publishedAt: new Date().toISOString(),
      messages: [{ id: "m1", role: "user", text: "hello", timestamp: 1, tool: null, images: [] }],
    };
    const shared = (await localCall(socketPath, "axo.session.share", { snapshot })) as { shareId: string; url: string };
    assert.equal(shared.url, `https://axo.leostera.dev/s/${shared.shareId}/relay-share`);
    const bucket = await api.mf.getR2Bucket("PUBLIC_SESSIONS") as unknown as R2Bucket;
    const stored = await bucket.get(`shares/${shared.shareId}.json`);
    assert.deepEqual(JSON.parse(await stored!.text()), snapshot);
    assert.equal(stored!.customMetadata?.hostId, hostId);
    await assert.rejects(
      localCall(socketPath, "axo.session.share", { snapshot: { ...snapshot, messages: [] } }),
      /refused/,
      "the cloud validates what it publishes",
    );

        // Another account sees nothing and cannot open the host.
    const stranger = await signIn(api);
    assert.deepEqual(await accountApi(api.url, stranger).listHosts(), []);
    await assert.rejects(
      accountApi(api.url, stranger).connectHost({ hostId, hostGeneration }, () => {}),
      "a client of another account cannot reach this host",
    );

    let clientClosedBecause: string | undefined;
    client = await remoteApi.connectHost({ hostId, hostGeneration }, (event) => {
      liveEvents.push(event);
      if (event.type === "host.data" && event.event.type === "terminal.output") {
        outputChunks.push(Buffer.from(event.event.data, "base64").toString("utf8"));
      }
    }, (error) => { clientClosedBecause = error.message; });
    await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.presence" && event.status === "online",
      "the app relay subscription",
      daemon,
    );

    const sessionList = await remoteApi.listHostSessions({ hostId, hostGeneration });
    assert.equal(sessionList.some((session) => session.sessionId === firstSession.sessionId), true);

    attachment = spawn("python3", [
      "-c",
      "import pty, sys; pty.spawn(sys.argv[1:])",
      axodBinary,
      "terminal-attach",
      "--attach-socket",
      join(serverDirectory, "attach.sock"),
      "--shell-id",
      String(firstSession.shells[0].shellId),
    ], {
      detached: true,
      stdio: ["pipe", "ignore", "ignore"],
      env: { ...process.env, HOME: root },
    });
    await new Promise<void>((resolveSpawn, rejectSpawn) => {
      attachment!.once("spawn", () => resolveSpawn());
      attachment!.once("error", rejectSpawn);
    });
    await waitForHostEvent(
      liveEvents,
      (event) => event.type === "host.data" && event.event.type === "shell.activity" && event.event.activity === "attached",
      "the isolated local PTY attachment",
      attachment,
    );

    const terminalText = `AXO_REMOTE_RELAY_${crypto.randomUUID().replaceAll("-", "")}`;
    const input = Buffer.from(`printf '${terminalText}\\n'\n`).toString("base64");
    const inputReply = await client.call("axo.remote.terminal.input", {
      target: { hostId, hostGeneration },
      sessionId: firstSession.sessionId,
      shellId: firstSession.shells[0].shellId,
      sequence: 0,
      data: input,
    });
    assert.equal(inputReply.accepted, true);

    // The call is wired through the Worker to the host, which refuses a Session it does not have
    // as not found; an empty prompt never leaves the Worker.
    await assert.rejects(
      client.call("axo.remote.session.prompt", {
        target: { hostId, hostGeneration },
        sessionId: crypto.randomUUID(),
        text: "run the tests",
      }),
      { code: -32004 },
    );
    await assert.rejects(
      client.call("axo.remote.session.prompt", {
        target: { hostId, hostGeneration },
        sessionId: firstSession.sessionId,
        text: "",
      }),
    );
    await waitFor("the streamed remote terminal output", 18_000, async () =>
      outputChunks.join("").includes(terminalText) ? true : undefined,
    );

    const createReply = await client.call("axo.remote.session.create", {
      target: { hostId, hostGeneration },
    });
    const created = createReply.session;
    assert.equal(created.hostId, hostId);
    await waitFor("the new session snapshot", 5_000, async () => {
      const current = await remoteApi.listHostSessions({ hostId, hostGeneration });
      return current.some((session) => session.sessionId === created.sessionId) ? true : undefined;
    }, daemon);

    // A person lists the host's Workspaces: names only, never directories on the Mac.
    const workspaceReply = await client.call("axo.remote.workspace.list", { target: { hostId, hostGeneration } });
    assert.ok(Array.isArray(workspaceReply.workspaces));
    assert.equal(JSON.stringify(workspaceReply).includes(serverDirectory), false);

    // A person renames the Session from afar; the new name reaches the account's snapshots.
    const renamed = await client.call("axo.remote.session.rename", {
      target: { hostId, hostGeneration },
      sessionId: created.sessionId,
      name: "Named from the relay",
    });
    assert.equal(renamed.saved, true);
    await waitFor("the renamed session snapshot", 5_000, async () => {
      const current = await remoteApi.listHostSessions({ hostId, hostGeneration });
      return current.find((session) => session.sessionId === created.sessionId)?.name === "Named from the relay"
        ? true
        : undefined;
    }, daemon);
    // A stale generation is refused before anything changes.
    await assert.rejects(
      client.call("axo.remote.session.rename", {
        target: { hostId, hostGeneration: crypto.randomUUID() },
        sessionId: created.sessionId,
        name: "stale host",
      }),
      /Stale host|-32002/,
    );

    // Terminal bytes are relayed, never stored, on either side.
    const accountStorage = await api.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", {
      name: account.accountId,
    });
    const storedSessions = await accountStorage.exec<{ snapshot_json: string }>(
      "SELECT snapshot_json FROM host_sessions_v2 WHERE host_id = ?",
      hostId,
    );
    assert.ok(storedSessions.length > 0, "session metadata is retained for the account");
    assert.equal(JSON.stringify(storedSessions).includes(terminalText), false);
    const databaseBytes = await readFile(join(serverDirectory, "axo.db")).catch(() => Buffer.alloc(0));
    assert.equal(databaseBytes.includes(Buffer.from(terminalText)), false);

    // Revoking the host closes its relay and keeps its metadata as offline.
    const revoked = await fetch(new URL(`api/v1/account/hosts/${hostId}/revoke`, api.url), {
      method: "POST",
      headers: account.headers,
    });
    assert.equal(revoked.status, 204);
    const offlineHost = await waitFor("the revoked host to be offline", 10_000, async () => {
      const host = (await remoteApi.listHosts()).find((item) => item.hostId === hostId);
      return host && host.status !== "online" ? host : undefined;
    });
    assert.ok(offlineHost.sessions.some((session) => session.sessionId === created.sessionId));
    await waitFor("the revoked host's clients to be disconnected", 5_000, async () => clientClosedBecause);
    // axod retries with its revoked credential and is refused.
    await waitFor("axod's reconnect with the revoked credential to be refused", 15_000, async () => {
      const log = await readFile(join(serverDirectory, "stderr.log"), "utf8");
      return /event=relay\.connection_retry reason=HTTP error: 403/.test(log) ? true : undefined;
    }, daemon);
    const afterRetry = (await remoteApi.listHosts()).find((item) => item.hostId === hostId);
    assert.notEqual(afterRetry?.status, "online", "a revoked host credential cannot reconnect");
  } finally {
    if (client) client.close();
    if (attachment) await terminate(attachment, true);
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
