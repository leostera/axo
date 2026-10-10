import { createServer } from "node:http";
import { once } from "node:events";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { TestContext } from "node:test";
import { ManagedPi, type PiProfile } from "../../pi/runtime.ts";
import { AmbientPi } from "../../pi/ambient.ts";

type ModelMessage = { role: string; content: unknown };
export async function fixture(t: TestContext) {
  const ambient = await AmbientPi.find(); // Never uses the repo's Pi devDependency, including under npm run.
  const root = await mkdtemp("/tmp/axo-real-pi-");
  const runtimes: Array<{ stop(): Promise<void> }> = [];
  let requests = 0;
  const releases: Array<() => void> = [];
  const observed: ModelMessage[][] = [];
  const server = createServer(async (request, response) => {
    let bytes = "";
    for await (const chunk of request) {
      bytes += chunk;
      if (Buffer.byteLength(bytes) > 1024 * 1024) { response.writeHead(413).end(); return; }
    }
    const messages = JSON.parse(bytes).messages as ModelMessage[];
    observed.push(messages); requests++;
    const user = [...messages].reverse().find(message => message.role === "user");
    const text = typeof user?.content === "string" ? user.content : JSON.stringify(user?.content);
    if (text.includes("FAIL_PROVIDER")) { response.writeHead(500).end("synthetic-provider-error"); return; }
    const toolAnswered = messages.at(-1)?.role === "tool";
    const hold = text.includes("HOLD") && !toolAnswered;
    const asks = text.includes("ASK") && !toolAnswered;
    const writes = text.includes("WRITE") && !toolAnswered;
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    function emit(delta: unknown, finish: string | null = null) {
      response.write(`data: ${JSON.stringify({ id: `completion-${requests}`, object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
    }
    emit({ role: "assistant" });
    emit({ content: "controlled\u2028output\u2029" });
    if (hold) await new Promise<void>(resolve => releases.push(resolve));
    if (response.destroyed) return;
    if (asks || writes) {
      emit({ tool_calls: [{ index: 0, id: `call-${requests}`, type: "function", function: {
        name: asks ? "fixture_ask" : "bash",
        arguments: asks ? "{}" : JSON.stringify({ command: "printf 'Pi-owned-tool' > marker.txt" }),
      } }] });
      emit({}, "tool_calls");
    } else { emit({ content: " completed" }); emit({}, "stop"); }
    response.end("data: [DONE]\n\n");
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Fixture model address");
  const port = address.port;
  const agent = join(root, "agent"); await mkdir(agent, { mode: 0o700 });
  await writeFile(join(agent, "settings.json"), JSON.stringify({ compaction: { enabled: false }, retry: { enabled: false }, quietStartup: true, packages: [] }), { mode: 0o600 });
  t.after(async () => {
    releases.splice(0).forEach(release => release());
    await Promise.all(runtimes.map(runtime => runtime.stop()));
    server.closeAllConnections();
    await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  async function profile(name = "first"): Promise<PiProfile> {
    const cwd = join(root, name); await mkdir(cwd, { mode: 0o700 });
    const sessionDirectory = join(cwd, "sessions"); await mkdir(sessionDirectory, { mode: 0o700 });
    return { pi: ambient,
      cwd, sessionDirectory,
      args: ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-approve", "--offline",
        "--extension", resolve("axod/tests/pi/provider.ts"), "--provider", "axo-pi-test", "--model", "fixture", "--tools", "bash,fixture_ask"],
      env: { PATH: process.env.PATH, HOME: root, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: "1", PI_TELEMETRY: "0", PI_SKIP_VERSION_CHECK: "1",
        AXO_TEST_MODEL_URL: `http://127.0.0.1:${port}/v1` },
    };
  }
  async function start(selected: PiProfile, persistence: Parameters<typeof ManagedPi.start>[1] = { kind: "fresh" }) {
    const runtime = await ManagedPi.start(selected, persistence); runtimes.push(runtime); return runtime;
  }
  return { root, profile, start, own: (runtime: { stop(): Promise<void> }) => runtimes.push(runtime), requests: () => requests, observed,
    release: () => releases.splice(0).forEach(release => release()),
  };
}
export async function eventually<T>(read: () => Promise<T>, accepts: (value: T) => boolean): Promise<T> {
  const until = Date.now() + 10000;
  while (Date.now() < until) {
    const value = await read();
    if (accepts(value)) return value;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error("Pi fixture observation deadline");
}
