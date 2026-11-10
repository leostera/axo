import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { watchLifeline } from "../src/lifeline.js";

const lifeline = fileURLToPath(new URL("../dist/lifeline.js", import.meta.url));

test("a Pi hears axod go when its lifeline ends, and only then", async () => {
  // The child reads its lifeline at descriptor 3, as Pi does; this test plays axod.
  const child = spawn(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `const { watchLifeline } = await import(${JSON.stringify(lifeline)});
       console.log(watchLifeline(process.env, () => { console.log("axod went"); process.exit(0); }) ? "watching" : "not watching");
       setInterval(() => {}, 1000);`,
    ],
    { env: { ...process.env, AXO_LIFELINE_FD: "3" }, stdio: ["ignore", "pipe", "inherit", "pipe"] },
  );
  let output = "";
  const said = (text: string) =>
    new Promise<void>(resolve => {
      const check = () => {
        if (output.includes(text)) resolve();
      };
      child.stdout?.on("data", chunk => {
        output += String(chunk);
        check();
      });
      check();
    });
  await said("watching");
  assert.ok(!output.includes("axod went"));
  const exited = new Promise<number | null>(resolve => child.on("exit", resolve));
  (child.stdio[3] as NodeJS.WritableStream & { destroy(): void }).destroy();
  await said("axod went");
  assert.equal(await exited, 0);
});

test("no lifeline, or one that is not a descriptor Pi may read, is not watched", () => {
  assert.equal(watchLifeline({}, () => assert.fail("never ends")), false);
  assert.equal(watchLifeline({ AXO_LIFELINE_FD: "two" }, () => assert.fail("never ends")), false);
  assert.equal(watchLifeline({ AXO_LIFELINE_FD: "1" }, () => assert.fail("never ends")), false);
});
