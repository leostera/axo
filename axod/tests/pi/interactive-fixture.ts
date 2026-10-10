import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile, realpath, lstat } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { TestContext } from "node:test";
import { AmbientPi } from "../../pi/ambient.ts";
import type { Record as ControlRecord } from "../../../pi-axo/control-protocol.ts";

export type Runtime = { host_generation: string; runtime_generation: string; target: { session_id: string; pane_id: string } };
export type State = { mode: string; stdinTTY: boolean; stdoutTTY: boolean; stderrTTY: boolean; rows: number; columns: number; pid: number; chatId: string; file: string; leafId: string | null; cwd: string; busy: boolean; interactionId: string | null; uiWaits: number; tools: string[]; pending: boolean; recovery: boolean };
export type Profile = { directory: string; sessions: string; argv: string[] };
export type Target = { runtime: Runtime; chatId: string; interactionId?: string };
export type History = { leafId: string | null; entries: any[]; branch: any[] };
export class FixtureFailure extends Error { constructor(readonly code: string) { super(`Owned interactive fixture: ${code}`); } }
type Pending = { resolve(value: any): void; reject(error: Error): void; timer: NodeJS.Timeout };
export async function eventually<T>(read: () => Promise<T>, accept: (value: T) => boolean): Promise<T> {
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) { const value = await read(); if (accept(value)) return value; await new Promise(resolve => setTimeout(resolve, 25)); }
  throw new FixtureFailure("observationDeadline");
}
export async function fixture(t: TestContext) {
  const ambient = await AmbientPi.find();
  const root = await mkdtemp("/tmp/axo-interactive-pi-");
  const replies = new Map<string, Pending>();
  const ready = new Map<string, State>();
  const states = new Map<string, State>();
  const gaps = new Set<string>();
  const requestCounts = new Map<string, number>();
  const gates: Array<() => void> = [];
  let driver: ChildProcessWithoutNullStreams | undefined;
  let next = 0, terminalBytes = 0;
  const key = (runtime: Runtime) => runtime.runtime_generation;
  const server = createServer(async (request, response) => {
    try {
      let raw = "";
      for await (const bytes of request) { raw += bytes; if (Buffer.byteLength(raw) > 1024*1024) { response.writeHead(413).end(); return; } }
      const name = request.url!.split("/")[1];
      const count = (requestCounts.get(name) ?? 0) + 1; requestCounts.set(name, count);
      const messages = JSON.parse(raw).messages;
      const user = [...messages].reverse().find(message => message.role === "user");
      const text = typeof user?.content === "string" ? user.content : JSON.stringify(user?.content);
      if (text.includes("FAIL_PROVIDER")) { response.writeHead(500).end("synthetic model error"); return; }
      const answered = messages.at(-1)?.role === "tool";
      const asks = text.includes("ASK") && !answered;
      const writes = text.includes("WRITE") && !answered;
      const slowTool = text.includes("SLOW_TOOL") && !answered;
      const probeFD = text.includes("PROBE_FD") && !answered;
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      const emit = (delta: unknown, finish: string | null = null) => response.write(`data: ${JSON.stringify({ id: `fixture-${count}`, object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
      emit({ role: "assistant" }); emit({ content: "real interactive\u2028output\u2029" });
      if (text.includes("HOLD") && !answered) await new Promise<void>(resolve => gates.push(resolve));
      if (response.destroyed) return;
      if (asks || writes || slowTool || probeFD) {
        const command = slowTool ? "sleep 30; printf unexpected > cancelled-tool.txt" : probeFD ? "python3 -c 'import os,stat; fds=[fd for fd in range(3,128) if os.path.exists(\"/dev/fd/\"+str(fd))]; print(fds); open(\"tool-fds.txt\",\"w\").write(str(fds))'" : "printf Pi-owned-tool > marker.txt";
        emit({ tool_calls: [{ index: 0, id: `call-${count}`, type: "function", function: { name: asks ? "fixture_ask" : "bash", arguments: asks ? "{}" : JSON.stringify({ command }) } }] });
        emit({}, "tool_calls");
      } else {
        if (text.includes("FLOOD")) for (let index = 0; index < 128; index++) emit({ content: "visible output ".repeat(80) });
        emit({ content: " complete" }); emit({}, "stop");
      }
      response.end("data: [DONE]\n\n");
    } catch { if (!response.headersSent) response.writeHead(400); response.end(); }
  });
  t.after(async () => {
    gates.splice(0).forEach(release => release());
    if (driver && driver.exitCode === null && driver.signalCode === null) {
      try { await call({ method: "shutdown" }); } catch {}
      driver.stdin.end();
      if (driver.exitCode === null && driver.signalCode === null) {
        const exited = once(driver, "exit"); const timer = setTimeout(() => driver?.kill("SIGKILL"), 6000);
        try { await exited; } finally { clearTimeout(timer); }
      }
    }
    for (const pending of replies.values()) { clearTimeout(pending.timer); pending.reject(new FixtureFailure("closed")); }
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
    await rm(root, { recursive: true, force: true });
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const address = server.address(); if (!address || typeof address === "string") throw new FixtureFailure("listen");
  const port = address.port;
  const stateDirectory = join(root, "daemon"); await mkdir(stateDirectory, { mode: 0o700 });
  driver = spawn(resolve("axod/target/debug/examples/interactive-pi-fixture"), [stateDirectory], { stdio: ["pipe", "pipe", "pipe"] });
  driver.stderr.resume(); // Never log diagnostics or terminal/transcript bodies.
  let buffer = Buffer.alloc(0);
  driver.stdout.on("data", bytes => {
    buffer = Buffer.concat([buffer, bytes]);
    for (;;) {
      const newline = buffer.indexOf(10); if (newline < 0) { if (buffer.length > 4*1024*1024) driver?.kill("SIGTERM"); return; }
      const raw = buffer.subarray(0, newline); buffer = buffer.subarray(newline+1);
      const record = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
      if (record.kind === "terminalBytes") { terminalBytes += record.count; continue; }
      if (record.kind === "gap") { gaps.add(key(record.runtime)); continue; }
      if (record.kind === "pi") {
        const value = record.record as ControlRecord<State>;
        if ("ready" in value) { ready.set(key(record.runtime), value.ready); continue; }
        if ("status" in value) { states.set(key(record.runtime), value.status); continue; }
        const { id, response } = value.reply;
        const reply = response === "dispatched" ? { result: { disposition: "dispatched" } }
          : "snapshot" in response ? { result: response.snapshot }
          : "history" in response ? { result: response.history }
          : { error: response.rejected };
        settle(`pi:${key(record.runtime)}:${id}`, reply);
      } else settle(`host:${record.id}`, record);
    }
  });
  const fail = () => { for (const pending of replies.values()) { clearTimeout(pending.timer); pending.reject(new FixtureFailure("hostExit")); } replies.clear(); };
  driver.on("exit", fail); driver.on("error", fail);
  function settle(id: string, reply: any) {
    const pending = replies.get(id); if (!pending) return;
    replies.delete(id); clearTimeout(pending.timer);
    if (reply.error !== undefined) pending.reject(new FixtureFailure(reply.error)); else pending.resolve(reply.result);
  }
  function wait(id: string) {
    return new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => { replies.delete(id); reject(new FixtureFailure("responseDeadline")); }, 12000);
      replies.set(id, { resolve, reject, timer });
    });
  }
  function call(command: Record<string, unknown>): Promise<any> {
    const id = ++next; const raw = JSON.stringify({ ...command, id }) + "\n";
    if (Buffer.byteLength(raw) > 65536) return Promise.reject(new FixtureFailure("capacity"));
    const result = wait(`host:${id}`);
    driver!.stdin.write(raw); return result;
  }
  async function profile(name = "first"): Promise<Profile> {
    const directory = join(root, name); await mkdir(directory, { mode: 0o700 });
    const sessions = join(directory, "sessions"); await mkdir(sessions, { mode: 0o700 });
    const agent = join(directory, "agent"); await mkdir(agent, { mode: 0o700 });
    await writeFile(join(agent, "settings.json"), JSON.stringify({ quietStartup: true, compaction: { enabled: false }, retry: { enabled: false }, packages: [], cacheWarming: { enabled: false } }), { mode: 0o600 });
    const config = join(directory, "provider.json"); await writeFile(config, JSON.stringify({ baseUrl: `http://127.0.0.1:${port}/${name}/v1` }), { mode: 0o600 });
    const argv = ["/bin/sh", "-c", 'export HOME="$1" PI_CODING_AGENT_DIR="$2" AXO_INTERACTIVE_FIXTURE_CONFIG="$3" PI_OFFLINE=1; shift 3; exec "$@"', "owned-pi", root, agent, config, ambient.executable,
      "--no-extensions", "--no-skills", "--no-themes", "--no-context-files", "--no-prompt-templates", "--no-approve", "--offline",
      "--extension", resolve("pi-axo/index.ts"), "--extension", resolve("pi-axo/tests/fixtures/provider.ts"),
      "--axo-managed-control", "--provider", "axo-interactive-fixture", "--model", "fixture", "--tools", "bash,fixture_ask", "--session-dir", sessions];
    return { directory, sessions, argv };
  }
  async function launch(profile: Profile, options: { commandId?: string; target?: Runtime["target"]; resume?: { file: string; chatId: string; cwd: string } } = {}) {
    profile = { ...profile, argv: [...profile.argv] };
    const resume = options.resume ? { ...options.resume } : undefined;
    const target = options.target ? { ...options.target } : { session_id: crypto.randomUUID(), pane_id: crypto.randomUUID() };
    const commandId = options.commandId ?? crypto.randomUUID();
    let argv = [...profile.argv];
    if (resume) {
      const binding = resume;
      const stat = await lstat(binding.file);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 4*1024*1024 || !binding.file.startsWith(profile.sessions+"/")) throw new FixtureFailure("badResume");
      const bytes = await readFile(binding.file); const header = JSON.parse(bytes.toString("utf8").split("\n")[0]);
      if (header.id !== binding.chatId || header.version !== 3 || await realpath(header.cwd) !== await realpath(profile.directory) || await realpath(binding.cwd) !== await realpath(profile.directory)) throw new FixtureFailure("badResume");
      argv.push("--session", binding.file);
    }
    const terminal = await call({ method: "start", commandId, target, launch: { directory: profile.directory, argv } });
    const runtime: Runtime = Object.freeze({ ...terminal.runtime, target: Object.freeze({ ...terminal.runtime.target }) });
    const initial = await eventually(async () => ready.get(key(runtime)), value => value !== undefined) as State;
    const bound = await command(runtime, { method: "bind", runtime });
    const targetPi: Target = Object.freeze({ runtime, chatId: bound.chatId });
    if (resume && (bound.chatId !== resume.chatId || bound.file !== resume.file)) throw new FixtureFailure("badBinding");
    return { runtime, terminal, initial, target: targetPi, profile,
      get: () => command(runtime, { method: "get", target: targetPi }) as Promise<State>,
      history: () => command(runtime, { method: "history", target: targetPi }) as Promise<History>,
      send: (text: string) => command(runtime, { method: "send", target: targetPi, text }),
      steer: (interactionId: string, text: string) => command(runtime, { method: "steer", target: { ...targetPi, interactionId }, text }),
      cancel: (interactionId: string) => command(runtime, { method: "cancel", target: { ...targetPi, interactionId } }),
      stop: () => call({ method: "stop", runtime }),
    };
  }
  async function command(runtime: Runtime, request: Record<string, unknown>) {
    if (typeof request.text === "string" && [...request.text].some(character => { const code = character.codePointAt(0)!; return code >= 0xd800 && code <= 0xdfff; })) throw new FixtureFailure("invalid");
    if (gaps.has(key(runtime))) throw new FixtureFailure("controlGap");
    const id = `${++next}`; const reply = wait(`pi:${key(runtime)}:${id}`);
    const dispatch = call({ method: "control", runtime, request: { ...request, id } });
    dispatch.catch(error => settle(`pi:${key(runtime)}:${id}`, { error: error instanceof FixtureFailure ? error.code : "unknown" }));
    await dispatch.catch(() => {}); return reply;
  }
  return { root, ambient, profile, launch, call, command,
    release: () => gates.splice(0).forEach(release => release()),
    requests: (name = "first") => requestCounts.get(name) ?? 0,
    terminalBytes: () => terminalBytes,
    state: (runtime: Runtime) => states.get(key(runtime)),
  };
}
