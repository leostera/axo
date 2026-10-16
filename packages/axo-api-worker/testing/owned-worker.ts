// Worker-only fixture owned/orchestrated by Rust. It never launches a daemon or Pi.
import { writeFile, stat } from "node:fs/promises";
import { join, isAbsolute } from "node:path";
import { harness } from "../tests/harness";

async function main() {
  const root = process.argv[2];
  if (!root || !isAbsolute(root)) throw new Error("Invalid owned fixture root");
  const metadata = await stat(root);
  if (!metadata.isDirectory() || (metadata.mode & 0o077) !== 0 || metadata.uid !== process.getuid?.()) throw new Error("Unsafe fixture root");
  const worker = await harness();
  try {
    const daemon = await worker.token("daemon");
    const client = await worker.token("client");
    // Synthetic Access assertions stay in private owned files, never argv/stdout/diagnostics.
    await writeFile(join(root, "relay.json"), JSON.stringify({ relay_url: worker.url.replace(/^http/, "ws"), allow_insecure_loopback: true, label: "Owned Pi RPC fixture", credentials: { kind: "access_assertion", assertion: daemon } }), { mode: 0o600, flag: "wx" });
    await writeFile(join(root, "client.json"), JSON.stringify({ url: worker.url, assertion: client }), { mode: 0o600, flag: "wx" });
    await new Promise<void>(resolve => { process.stdin.once("end", resolve); process.stdin.resume(); });
  } finally { await worker.close(); }
}
void main().catch(() => { process.stderr.write("Owned Worker fixture failed\n"); process.exitCode = 1; });
