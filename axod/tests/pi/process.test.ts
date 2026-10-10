// Negative private-channel tests only. These processes are NOT Pi/chat execution acceptance.
import { test } from "node:test";
import assert from "node:assert/strict";
import { PiFailure, PiProcess } from "../../pi/process.ts";

test("private Pi framing preserves Unicode separators and split UTF-8 without reading stderr", async t => {
  const program = `process.stdin.once('data', raw => {
    const request=JSON.parse(raw);
    process.stderr.write('synthetic-sensitive-diagnostic');
    const bytes=Buffer.from(JSON.stringify({type:'response',id:request.id,command:request.type,success:true,data:{text:'界\\u2028value\\u2029'}})+'\\n');
    const cut=bytes.indexOf(Buffer.from('界'))+1;
    process.stdout.write(bytes.subarray(0,cut));
    setTimeout(()=>process.stdout.write(bytes.subarray(cut)),5);
  });`;
  const child = new PiProcess(process.execPath, ["-e", program], process.cwd(), {});
  t.after(() => child.stop());
  assert.deepEqual((await child.request("get_state")).data, { text: "界\u2028value\u2029" });
});

for (const [name, output] of [
  ["malformed", "'{not-json}\\n'"],
  ["uncorrelated", "JSON.stringify({type:'response',id:'wrong',command:request.type,success:true})+'\\n'"],
  ["wrong command", "JSON.stringify({type:'response',id:request.id,command:'other',success:true})+'\\n'"],
  ["oversized", "'x'.repeat(4*1024*1024+1)+'\\n'"],
] as const) {
  test(`${name} private record is outcome-unknown, fences control, and never leaks body diagnostics`, async t => {
    const program = `process.stdin.once('data', raw => { const request=JSON.parse(raw); process.stdout.write(${output}); });`;
    const child = new PiProcess(process.execPath, ["-e", program], process.cwd(), {});
    t.after(() => child.stop());
    await assert.rejects(child.request("prompt", { message: "synthetic-body" }), error => error instanceof PiFailure && error.kind === "unknown" && !error.message.includes("synthetic-body"));
    await assert.rejects(child.request("prompt", { message: "No replay" }), error => error instanceof PiFailure && error.kind === "recovery");
  });
}

test("owned subprocess exit after command dispatch is unknown, not known rejection", async t => {
  const child = new PiProcess(process.execPath, ["-e", "process.stdin.once('data',()=>process.exit(7));"], process.cwd(), {});
  t.after(() => child.stop());
  await assert.rejects(child.request("prompt", { message: "Attempt once" }), error => error instanceof PiFailure && error.kind === "unknown");
});

test("bounded pending admission rejects capacity before dispatch and closes every owned waiter", async () => {
  const child = new PiProcess(process.execPath, ["-e", "process.stdin.resume();"], process.cwd(), {});
  const pending = Array.from({ length: 16 }, () => child.request("get_state").catch(error => error));
  await assert.rejects(child.request("get_state"), error => error instanceof PiFailure && error.kind === "capacity");
  await Promise.all([child.stop(), child.stop()]);
  for (const error of await Promise.all(pending)) assert.ok(error instanceof PiFailure && error.kind === "unknown");
});
