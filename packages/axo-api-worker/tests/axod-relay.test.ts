import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { harness, signIn } from "./harness";
import { listHosts, localCall, terminate, TestAccountClient, waitFor } from "./axod-support";

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
  let client: TestAccountClient | undefined;
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
    assert.deepEqual(await listHosts(api.url, account), [], "an unpaired host is not visible to anyone");
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
      (await listHosts(api.url, account)).find((host) => host.status === "online"),
    daemon);
    assert.equal(registered.stale, false);
    const { hostId, hostGeneration } = registered;
    const target = { hostId, hostGeneration };

    // The account's client lists the host and the Sessions axod synced, never paths or PTYs.
    client = await TestAccountClient.connect(api.url, account);
    assert.deepEqual(client.hosts.map((host) => [host.hostId, host.online]), [[hostId, true]]);
    const firstSession = await waitFor("axod's initial Session in the client's list", 15_000, async () =>
      [...client!.sessions.values()].find((session) => session.hostId === hostId), daemon);
    assert.equal(JSON.stringify([...client.sessions.values()]).match(/attachSocketPath|ptyDevice|terminalOutput|pi-sessions/gi), null);
    const command = client.connection.command.bind(client.connection);

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

    // Another account sees nothing and cannot reach the host.
    const stranger = await signIn(api);
    assert.deepEqual(await listHosts(api.url, stranger), []);
    const strangerClient = await TestAccountClient.connect(api.url, stranger);
    assert.deepEqual(strangerClient.hosts, []);
    assert.equal(strangerClient.sessions.size, 0);
    // In protocol 3 it has no socket on this host, so nothing is sent: refused as offline (-32005).
    await assert.rejects(strangerClient.connection.command("axo.remote.workspace.list", { target }), { code: -32005 }, "a client of another account cannot reach this host");
    strangerClient.close();

    // The call is wired through the Worker to the host, which refuses a Session it does not have
    // as not found; an empty prompt never leaves the Worker.
    await assert.rejects(
      command("axo.remote.session.prompt", { target, sessionId: crypto.randomUUID(), text: "run the tests" }),
      { code: -32004 },
    );
    await assert.rejects(command("axo.remote.session.prompt", { target, sessionId: firstSession.sessionId, text: "" }));

    const created = (await command("axo.remote.session.create", { target })).session;
    assert.equal(created.hostId, hostId);
    await waitFor("the new Session in the client's list", 10_000, async () => client!.sessions.get(created.sessionId), daemon);

    // A person lists the host's Workspaces: names only, never directories on the Mac.
    const workspaceReply = await command("axo.remote.workspace.list", { target });
    assert.ok(Array.isArray(workspaceReply.workspaces));
    assert.equal(JSON.stringify(workspaceReply).includes(serverDirectory), false);

    // A person renames the Session from afar; the new name reaches the account's clients.
    const renamed = await command("axo.remote.session.rename", { target, sessionId: created.sessionId, name: "Named from the relay" });
    assert.equal(renamed.saved, true);
    await waitFor("the renamed Session", 10_000, async () =>
      client!.sessions.get(created.sessionId)?.metadata.name === "Named from the relay" ? true : undefined, daemon);
    // A stale generation is refused before anything changes.
    await assert.rejects(
      command("axo.remote.session.rename", { target: { hostId, hostGeneration: crypto.randomUUID() }, sessionId: created.sessionId, name: "stale host" }),
      /Stale host|-32002/,
    );

    // Revoking the host closes its relay; its clients see it go offline, its Sessions stay listed.
    const revoked = await fetch(new URL(`api/v1/account/hosts/${hostId}/revoke`, api.url), {
      method: "POST",
      headers: account.headers,
    });
    assert.equal(revoked.status, 204);
    await waitFor("the revoked host to be offline", 10_000, async () => {
      const host = (await listHosts(api.url, account)).find((item) => item.hostId === hostId);
      return host && host.status !== "online" ? host : undefined;
    });
    await waitFor("the client to see the host offline", 10_000, async () =>
      client!.hosts.some((host) => host.hostId === hostId && !host.online) ? true : undefined);
    // axod retries with its revoked credential and is refused.
    await waitFor("axod's reconnect with the revoked credential to be refused", 15_000, async () => {
      const log = await readFile(join(serverDirectory, "stderr.log"), "utf8");
      return /event=relay\.connection_retry reason=HTTP error: 403/.test(log) ? true : undefined;
    }, daemon);
    const afterRetry = (await listHosts(api.url, account)).find((item) => item.hostId === hostId);
    assert.notEqual(afterRetry?.status, "online", "a revoked host credential cannot reconnect");
  } finally {
    client?.close();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
