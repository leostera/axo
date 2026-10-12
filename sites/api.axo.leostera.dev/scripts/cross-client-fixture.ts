import { harness, root } from "../tests/harness";
import { accessHeaders } from "../testing/access-headers";
import { chmod, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:https";
import { request } from "node:http";
import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";

// Local Access edge adapter only: forward cookies as assertions, but the actual
// Worker still verifies the fixture RSA signature, audience, expiry and role.
function headers(incoming: IncomingMessage, upstream: URL) {
  const headers = { ...incoming.headers, host: upstream.host };
  const cookie = incoming.headers.cookie?.split(";").map(value => value.trim())
    .find(value => value.startsWith("CF_Authorization="))?.slice("CF_Authorization=".length);
  if (cookie) Object.assign(headers, accessHeaders(cookie));
  return headers;
}
const directory = await realpath(await mkdtemp(join(tmpdir(), "axo-cross-client-")));
let api: Awaited<ReturnType<typeof harness>> | undefined;
let proxy: ReturnType<typeof createServer> | undefined;
const sockets = new Set<Duplex>();
try {
  await writeFile(join(directory, "tls.cnf"), "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=Axo disposable simulator test\n[extensions]\nsubjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n", { mode: 0o600, flag: "wx" });
  const generated = spawnSync("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
    "-config", join(directory, "tls.cnf"), "-keyout", join(directory, "key.pem"), "-out", join(directory, "certificate.pem")],
    { stdio: "ignore" });
  if (generated.status !== 0) throw new Error("Disposable TLS certificate generation failed");
  await chmod(join(directory, "key.pem"), 0o600);
  await chmod(join(directory, "certificate.pem"), 0o600);
  // No host trust-store change: Rust installs this root in its new simulator only.
  api = await harness({ audience: "b4ce8a1f58bff7fd09c1d2b64fdbbd7a2098df4a0e46850b78caa05783676073" });
  const upstream = new URL(api.url);
  proxy = createServer({ key: await readFile(join(directory, "key.pem")), cert: await readFile(join(directory, "certificate.pem")) }, (incoming, response) => {
    const outgoing = request(new URL(incoming.url ?? "/", upstream), { method: incoming.method, headers: headers(incoming, upstream) }, reply => {
      response.writeHead(reply.statusCode ?? 502, reply.headers);
      reply.pipe(response);
    });
    outgoing.on("error", () => { if (!response.headersSent) response.writeHead(502); response.end(); });
    incoming.on("error", () => outgoing.destroy());
    incoming.pipe(outgoing);
  });
  proxy.maxConnections = 32;
  proxy.requestTimeout = 15000;
  proxy.on("connection", socket => { sockets.add(socket); socket.on("close", () => sockets.delete(socket)); });
  proxy.on("upgrade", (incoming, downstream, initial) => {
    const outgoing = request(new URL(incoming.url ?? "/", upstream), { headers: headers(incoming, upstream) });
    outgoing.on("upgrade", (reply, socket, head) => {
      downstream.write(`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage}\r\n` +
        Object.entries(reply.headers).map(([key, value]) => `${key}: ${value}`).join("\r\n") + "\r\n\r\n");
      if (head.length) downstream.write(head);
      if (initial.length) socket.write(initial);
      downstream.pipe(socket).pipe(downstream);
      downstream.on("error", () => socket.destroy());
      socket.on("error", () => downstream.destroy());
      downstream.on("close", () => socket.destroy());
      socket.on("close", () => downstream.destroy());
    });
    outgoing.on("response", reply => { downstream.end(`HTTP/1.1 ${reply.statusCode} Rejected\r\nConnection: close\r\n\r\n`); reply.resume(); });
    outgoing.on("error", () => downstream.destroy());
    outgoing.end();
  });
  await new Promise<void>((resolve, reject) => { proxy!.once("error", reject); proxy!.listen(0, "127.0.0.1", resolve); });
  const address = proxy.address();
  if (!address || typeof address === "string") throw new Error("Owned TLS listener unavailable");
  await writeFile(join(directory, "relay.json"), JSON.stringify({ relay_url: api.url.replace("http:", "ws:"),
    label: "Owned packaged Mac fixture", allow_insecure_loopback: true,
    credentials: { kind: "access_assertion", assertion: await api.token("daemon", {}, "15m") } }), { mode: 0o600, flag: "wx" });
  await writeFile(join(directory, "phone.json"), JSON.stringify({ version: 1, origin: `https://127.0.0.1:${address.port}`,
    cookie: await api.token("client", {}, "15m") }), { mode: 0o600, flag: "wx" });
  const child = spawn("cargo", ["run", "--manifest-path", join(root, "axod/Cargo.toml"), "--locked", "--offline", "--example", "app-startup-fixture", "--", join(root, "dist/Axo.app")],
    { stdio: "inherit", env: { ...process.env, AXO_APP_SELF_TEST_CASE: "cross-client", AXO_CROSS_CLIENT_ROOT: directory } });
  const status = await new Promise<number | null>((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
  if (status !== 0) throw new Error("Cross-client acceptance failed; Rust retained its private diagnostics");
} finally {
  for (const socket of sockets) socket.destroy();
  if (proxy) await new Promise<void>(resolve => proxy!.close(() => resolve()));
  await api?.close();
  await rm(directory, { recursive: true, force: true });
}
