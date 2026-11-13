import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { watchLifeline } from "../src/lifeline.js";

// The source, through tsx: the test's runfiles hold src/, not the built dist/.
const lifeline = fileURLToPath(new URL("../src/lifeline.ts", import.meta.url));

test("a Pi hears axod go when its lifeline ends, and only then", async () => {
  // The child reads its lifeline at descriptor 3, as Pi does; this test plays axod.
  const child = spawn(
    process.execPath,
    [
      "--import",
      "tsx",
      "--input-type=module",
      "-e",
      `const { watchLifeline } = await import(${JSON.stringify(lifeline)});
       console.log(watchLifeline(process.env, () => { console.log("axod went"); process.exit(0); }) ? "watching" : "not watching");
       setInterval(() => {}, 1000);`,
    ],
    { env: { ...process.env, AXO_LIFELINE_FD: "3" }, stdio: ["ignore", "pipe", "inherit", "pipe"] },
  );
  let output = "";
  let gone: number | null | undefined;
  child.on("exit", code => (gone = code));
  // A child that dies before saying it fails the test now, instead of leaving it waiting.
  const said = (text: string) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (output.includes(text)) resolve();
        else if (gone !== undefined) reject(new Error(`the child exited (${gone}) before saying "${text}": ${output}`));
      };
      child.stdout?.on("data", chunk => {
        output += String(chunk);
        check();
      });
      child.on("exit", check);
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
