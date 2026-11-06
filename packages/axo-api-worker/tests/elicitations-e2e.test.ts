import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { ELICITATION_ERRORS, type Elicitation, type ElicitationResolved } from "@axo/protocol";
import { harness, signInNative } from "./harness";
import { accountApi, listHosts, localCall, terminate, waitFor, trustedDevice } from "./axod-support";

/**
 * An agent asks its person a yes-or-no question (RFD0029), with nothing faked but the sign-in
 * provider and Pi: the agent's `elicitation_request` tool, served by a real `axod mcp`, waits in
 * a real axod; the question reaches the person's phone through the cloud; the phone's answer comes
 * back the same way, and the agent's call returns it. A second answer, from another device, is
 * refused, and `axod.sock` has no way to answer at all.
 */
test("an agent's question reaches the person's phone, their answer returns to the agent, and it approves no tool", async () => {
  const binary = process.env.AXOD_BINARY;
  assert.ok(binary, "set AXOD_BINARY to the Bazel-built axod binary");
  const axodBinary = resolve(process.cwd(), binary);
  assert.ok(existsSync(axodBinary), `axod binary must exist at ${axodBinary}`);

  const api = await harness();
  const root = await mkdtemp(join(tmpdir(), "axo-elicitations-"));
  const serverDirectory = join(root, "server");
  const socketPath = join(root, "axod.sock");
  const pi = join(dirname(fileURLToPath(import.meta.url)), "fake-pi.mjs");
  await mkdir(serverDirectory, { recursive: true, mode: 0o700 });
  const device = await trustedDevice(serverDirectory);

  let daemon: ChildProcess | undefined;
  let mcp: ChildProcess | undefined;
  const connections: Array<{ close(): void }> = [];
  try {
    daemon = spawn(axodBinary, [
      "--server-dir", serverDirectory, "--socket", socketPath, "--relay-url", api.url, "--host-credentials", "files",
    ], { stdio: "ignore", env: {
      ...process.env, HOME: root, AXO_PI_EXECUTABLE: pi, AXO_FAKE_PI_STARTUP_MS: "200",
      AXO_PI_EXTENSION_PATH: fileURLToPath(new URL("../../../crates/axo-server/testdata/pi-extension.js", import.meta.url)),
    } });
    await waitFor("the axod socket", 15_000, async () => (existsSync(socketPath) ? true : undefined), daemon);

    const person = await signInNative(api);
    const pairing = await fetch(new URL("api/v1/account/host-pairings", api.url), { method: "POST", headers: person.headers });
    const { code } = (await pairing.json()) as { code: string };
    assert.equal(((await localCall(socketPath, "axo.relay.link", { code })) as { linked: boolean }).linked, true);
    const host = await waitFor("the Mac online", 20_000, async () =>
      (await listHosts(api.url, person)).find((candidate) => candidate.status === "online"), daemon);

    // The person has a phone and a browser open.
    const asked: Array<{ device: string; hostId: string; elicitation: Elicitation }> = [];
    const settled: Array<{ device: string; resolved: ElicitationResolved }> = [];
    const open = async (device: string) => {
      const connection = await accountApi(api.url, person).connect(`${device}-${crypto.randomUUID().slice(0, 8)}`, {
        elicitationRequested: (hostId, elicitation) => asked.push({ device, hostId, elicitation }),
        elicitationResolved: (_hostId, resolved) => settled.push({ device, resolved }),
      });
      connections.push(connection);
      return connection;
    };
    const phone = await open("phone");
    const browser = await open("browser");

    const { sessions } = (await localCall(socketPath, "axo.session.list")) as { sessions: Array<{ id: string }> };
    const sessionId = sessions[0]!.id;

    // The agent's MCP server, as Pi starts it for this Session.
    mcp = spawn(axodBinary, ["mcp"], { stdio: ["pipe", "pipe", "ignore"], env: { ...process.env, AXO_SOCKET: socketPath, AXO_SESSION_ID: sessionId } });
    const replies = createInterface({ input: mcp.stdout! });
    const answers = new Map<number, (value: { result?: { structuredContent?: { action: string; id: string }; isError?: boolean } }) => void>();
    replies.on("line", (line) => {
      const reply = JSON.parse(line) as { id: number };
      answers.get(reply.id)?.(reply as never);
    });
    let nextId = 0;
    const callMcp = (method: string, params: unknown) => new Promise<{ result?: { structuredContent?: { action: string; id: string }; isError?: boolean; tools?: Array<{ name: string }> } }>((done) => {
      const id = ++nextId;
      answers.set(id, done as never);
      mcp!.stdin!.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
    const listed = await callMcp("tools/list", {});
    assert.ok(listed.result?.tools?.some((tool) => tool.name === "elicitation_request"));

    // The agent asks, naming another Session; it can only ask for its own.
    const question = callMcp("tools/call", {
      name: "elicitation_request",
      arguments: { message: "Delete the branch feat/old-ui?", sessionId: crypto.randomUUID() },
    });
    const shown = await waitFor("the question on both devices", 15_000, async () =>
      asked.length >= 2 ? asked : undefined, daemon);
    const elicitation = shown[0]!.elicitation;
    assert.deepEqual(new Set(shown.map((entry) => entry.device)), new Set(["phone", "browser"]));
    assert.equal(shown[0]!.hostId, host.hostId);
    assert.equal(elicitation.sessionId, sessionId);
    assert.equal(elicitation.message, "Delete the branch feat/old-ui?");
    assert.equal(elicitation.askedBy, "agent");
    assert.deepEqual(((await localCall(socketPath, "axo.elicitation.list")) as { elicitations: Elicitation[] }).elicitations.map((e) => e.id), [elicitation.id]);

    // On axod.sock only Axo.app answers, by code signature: a script cannot.
    await assert.rejects(localCall(socketPath, "axo.elicitation.resolve", { elicitationId: elicitation.id, action: "accept" }), /only the person answers/iu);
    // Nor can a script ask as one of Axo's tools; only `axod mcp` itself can.
    await assert.rejects(localCall(socketPath, "axo.elicitation.request", { sessionId, message: "Pay?", askedBy: "computerUse" }), /only Axo's own tools/iu);

    // The phone says yes; the agent's call returns it; both devices dismiss the card.
    await device.answer(phone, host.hostId, elicitation.id, "accept");
    const outcome = await question;
    assert.equal(outcome.result?.isError, undefined);
    assert.deepEqual(outcome.result?.structuredContent, { id: elicitation.id, action: "accept" });
    await waitFor("the card dismissed on both devices", 10_000, async () => settled.length >= 2 ? true : undefined, daemon);
    assert.ok(settled.every((entry) => entry.resolved.id === elicitation.id && entry.resolved.action === "accept"));

    // The browser's answer comes too late and changes nothing.
    await assert.rejects(device.answer(browser, host.hostId, elicitation.id, "decline"),
      (error: { code?: number }) => error.code === ELICITATION_ERRORS.notPending);

    // A No is a No.
    // An agent passing askedBy is still asking as itself.
    const second = callMcp("tools/call", { name: "elicitation_request", arguments: { message: "Push to main?", askedBy: "computerUse" } });
    const next = await waitFor("the second question", 15_000, async () =>
      asked.find((entry) => entry.elicitation.message === "Push to main?"), daemon);
    assert.equal(next.elicitation.askedBy, "agent");
    // Each answer counts only with its device's signature over it (RFD0029): a signature
    // replayed onto this question, or changed to a Yes, is refused. Any device in the account
    // may answer.
    const { newDeviceKey, signAnswer } = await import("@axo/app");
    const replayed = await signAnswer(device.key, "Leo's iPhone", elicitation.id, "decline");
    await assert.rejects(browser.resolveElicitation(host.hostId, next.elicitation.id, "decline", replayed),
      (error: { code?: number }) => error.code === ELICITATION_ERRORS.badSignature);
    const no = await signAnswer(device.key, "Leo's iPhone", next.elicitation.id, "decline");
    await assert.rejects(browser.resolveElicitation(host.hostId, next.elicitation.id, "accept", no),
      (error: { code?: number }) => error.code === ELICITATION_ERRORS.badSignature);
    // This browser's own key, which the Mac has never seen, answers.
    const browserKey = await newDeviceKey();
    await browser.resolveElicitation(host.hostId, next.elicitation.id, "decline", await signAnswer(browserKey, "Safari on Mac", next.elicitation.id, "decline"));
    assert.equal((await second).result?.structuredContent?.action, "decline");

    // Tools ask; agents cannot approve. The answer to the agent's own question approves nothing:
    // computer refuses it as an argument, before anything runs.
    type ToolResult = { result?: { isError?: boolean; content?: Array<{ text?: string }> } };
    const text = (reply: ToolResult) => reply.result?.content?.[0]?.text ?? "";
    const pay = { tool: "click", args: { role: "AXButton", name: "Pay now" } };
    const presented = (await callMcp("tools/call", { name: "computer", arguments: { ...pay, elicitationId: elicitation.id } })) as ToolResult;
    assert.equal(presented.result?.isError, true);
    assert.match(text(presented), /takes no `elicitationId`/u);

    // confirm: true asks the person instead of approving; the tool's own question names the
    // action, and a No means nothing runs.
    const confirmed = callMcp("tools/call", { name: "computer", arguments: { ...pay, confirm: true } }) as Promise<ToolResult>;
    const gateQuestion = await waitFor("the gate's question", 15_000, async () =>
      asked.find((entry) => entry.elicitation.message.startsWith("Computer use wants to:")), daemon);
    assert.match(gateQuestion.elicitation.message, /click AXButton "Pay now"/u);
    assert.match(gateQuestion.elicitation.message, /The agent asked to check with you first/u);
    assert.equal(gateQuestion.elicitation.askedBy, "computerUse");
    await device.answer(phone, host.hostId, gateQuestion.elicitation.id, "decline");
    const declined = await confirmed;
    assert.equal(declined.result?.isError, true);
    assert.equal(text(declined), "Not done: the person declined.");
  } finally {
    for (const connection of connections) connection.close();
    mcp?.kill();
    if (daemon) await terminate(daemon);
    await api.close();
    await rm(root, { recursive: true, force: true });
  }
});
