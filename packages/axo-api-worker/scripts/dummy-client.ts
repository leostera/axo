import { open } from "node:fs/promises";
import { constants } from "node:fs";
import { isAbsolute } from "node:path";
import { Peer } from "../testing/client";
import { accessHeaders } from "../testing/access-headers";
import {
  replySchema,
  machineListResultSchema,
  results,
  uuid,
  startSchema,
} from "@axo/protocol";

async function assertion(path: string): Promise<string> {
  if (!isAbsolute(path))
    throw new Error("Absolute private credential file required");
  const file = await open(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const stat = await file.stat();
    if (
      !stat.isFile() ||
      (stat.mode & 0o777) !== 0o600 ||
      stat.nlink !== 1 ||
      stat.uid !== process.getuid?.() ||
      stat.size > 8192
    )
      throw new Error("Owned mode-0600 credential file required");
    const buffer = Buffer.alloc(8193);
    const { bytesRead } = await file.read(buffer);
    if (bytesRead > 8192) throw new Error("Credential limit");
    const token = buffer.subarray(0, bytesRead).toString("utf8").trim();
    if (!token || /[\r\n]/.test(token)) throw new Error("Invalid credential");
    return token;
  } finally {
    await file.close();
  }
}
async function boundedJson(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Missing response");
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let text = "";
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return JSON.parse(text + decoder.decode());
      bytes += value.byteLength;
      if (bytes > 65536) {
        await reader.cancel();
        throw new Error("Response limit");
      }
      text += decoder.decode(value, { stream: true });
    }
  } finally {
    reader.releaseLock();
  }
}
let mutationAttempted = false;

async function main() {
  const [endpoint, credentialFile, ...flags] = process.argv.slice(2);
  if (!endpoint || !credentialFile)
    throw new Error(
      "Usage: dummy-client.ts https://axo.leostera.dev/ /absolute/private/client.jwt [--machine UUID] [--start-approved PROFILE] [--allow-loopback]",
    );
  let machineId: string | undefined;
  let profileId: string | undefined;
  let allowLoopback = false;
  for (let index = 0; index < flags.length; index++) {
    if (flags[index] === "--machine") machineId = uuid.parse(flags[++index]);
    else if (flags[index] === "--start-approved") profileId = flags[++index];
    else if (flags[index] === "--allow-loopback") allowLoopback = true;
    else throw new Error("Unknown argument");
  }
  if (profileId && !machineId)
    throw new Error("An explicit machine is required for mutation");
  const url = new URL(endpoint);
  const local =
    allowLoopback &&
    url.protocol === "http:" &&
    ["127.0.0.1", "[::1]"].includes(url.hostname);
  if (
    (url.protocol !== "https:" && !local) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/"
  )
    throw new Error("HTTPS API base URL required");
  const token = await assertion(credentialFile);
  const response = await fetch(new URL("v1/rpc", url), {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(10000),
    headers: accessHeaders(token),
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: "discover",
      method: "axo.machine.list",
      params: {},
    }),
  });
  if (!response.ok) throw new Error("Discovery failed");
  const reply = replySchema.parse(await boundedJson(response));
  if (!("result" in reply)) throw new Error("Discovery rejected");
  const catalog = machineListResultSchema.parse(reply.result);
  console.log(JSON.stringify(catalog, null, 2));
  if (!machineId) return; // Default invocation is discovery-only.
  const machine = catalog.machines.find(
    (value) => value.machineId === machineId,
  );
  if (!machine?.online || !machine.hostGeneration)
    throw new Error("Explicit machine unavailable");
  const target = { machineId, hostGeneration: machine.hostGeneration };
  const peer = await Peer.connect(url.href, token, machineId, "client");
  try {
    await peer.negotiate();
    const listed = await peer.call("axo.runtime.list", { target });
    if (!("result" in listed)) throw new Error("Read rejected");
    console.log(
      JSON.stringify(results["axo.runtime.list"].parse(listed.result), null, 2),
    );
    if (!profileId) return;
    const commandId = crypto.randomUUID();
    const params = startSchema.parse({
      commandId,
      target: {
        ...target,
        sessionId: crypto.randomUUID(),
        paneId: crypto.randomUUID(),
      },
      profileId,
    });
    // Capture the complete non-secret mutation intent before dispatch for later reconciliation.
    console.log(JSON.stringify(params));
    mutationAttempted = true;
    const launched = await peer.call("axo.runtime.startApproved", params);
    if (!("result" in launched)) throw new Error("Mutation rejected");
    console.log(
      JSON.stringify(
        results["axo.runtime.startApproved"].parse(launched.result),
        null,
        2,
      ),
    );
  } finally {
    peer.close();
  }
}
main().catch(() => {
  console.error(
    mutationAttempted
      ? "Smoke test failed after a mutation attempt; outcome may be unknown. Reconcile commandId; no automatic retry was attempted."
      : "Smoke test failed before any mutation attempt; no work was launched by this client. No automatic retry was attempted.",
  );
  process.exitCode = 1;
});
