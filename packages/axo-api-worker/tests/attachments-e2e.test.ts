import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { harness, signInNative } from "./harness";
import { listHosts, localCall, terminate, TestAccountClient, waitFor } from "./axod-support";

/**
 * A photo from the phone reaching Pi (RFD0030), with nothing faked but the sign-in provider and
 * Pi: the phone uploads the asset to its account, prompts with it, and a real axod fetches it
 * with its host credential, checks it, and hands Pi the path. An attachment the account doesn't
 * have refuses the whole prompt, and Pi gets nothing.
 */
test("a photo attached on the phone reaches Pi on the Mac as a checked local file", async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-attachments-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  const typedIntoPi = join(root, "pi-typed.log");
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
      ...process.env, HOME: root, AXO_PI_EXECUTABLE: pi, AXO_FAKE_PI_LOG: typedIntoPi, AXO_FAKE_PI_STARTUP_MS: "200",
      AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
    } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    const phone = await signInNative(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: phone.headers });
    const { code } = (await pairing.json()) as { code: string };
    assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);
    const host = await waitFor("the Mac online", 20_000, async () =>
      (await listHosts(api.url, phone)).find((candidate) => candidate.status === "online"), daemon);
    const target = { hostId: host.hostId, hostGeneration: host.hostGeneration };
    client = await TestAccountClient.connect(api.url, phone);
    const command = client.connection.command.bind(client.connection);
    const projectDirectory = join(root, "project");
    await mkdir(projectDirectory);
    const local = await localCall(socketPath, "axo.session.create", { folder: projectDirectory }) as { id: string };
    const { session } = await command("axo.remote.session.create", { target, like: local.id });

    // The phone uploads the photo first, then prompts with it.
    const photo = new TextEncoder().encode("\u0089PNG pretend photo of a whiteboard");
    const hex = createHash("sha256").update(photo).digest("hex");
    const uploaded = await fetch(new URL(`api/v1/account/assets/${hex}`, api.url), {
      method: "PUT",
      headers: { ...phone.headers, "Content-Type": "image/png", "X-Axo-Asset-Name": "whiteboard.png" },
      body: photo as BodyInit,
    });
    assert.equal(uploaded.status, 201);
    const attachment = { asset: `sha256:${hex}`, name: "whiteboard.png", mimeType: "image/png" as const, size: photo.byteLength };

    const accepted = await command("axo.remote.session.prompt", {
      target, sessionId: session.sessionId, text: "", commandId: crypto.randomUUID(), attachments: [attachment],
    });
    assert.equal(accepted.accepted, true);
    const typed = await waitFor("the attachment reaching Pi", 20_000, async () => {
      const text = await readFile(typedIntoPi, "utf8").catch(() => "");
      return text.includes("ATTACHED:") ? text : undefined;
    }, daemon);
    const line = typed.split("\n").find((entry) => entry.startsWith("ATTACHED:"))!;
    const [given] = JSON.parse(line.slice("ATTACHED:".length)) as Array<{ path: string; asset: string; name: string; mimeType: string; size: number }>;
    assert.deepEqual({ ...given, path: undefined }, { ...attachment, path: undefined });
    assert.ok(given!.path.endsWith(`/assets/${hex}/whiteboard.png`), given!.path);
    assert.deepEqual(new Uint8Array(await readFile(given!.path)), photo, "Pi gets the bytes the phone uploaded");

    // An attachment the account doesn't have: the prompt is refused, and Pi hears nothing of it.
    const missing = { ...attachment, asset: `sha256:${"0".repeat(64)}`, name: "gone.png" };
    await assert.rejects(
      command("axo.remote.session.prompt", { target, sessionId: session.sessionId, text: "and this one", commandId: crypto.randomUUID(), attachments: [missing] }),
      /no longer in the account|-32010/u,
    );
    await new Promise((settle) => setTimeout(settle, 500));
    assert.equal((await readFile(typedIntoPi, "utf8")).includes("and this one"), false);
  } finally {
    client?.close();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
