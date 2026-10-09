import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, realpath, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const execute = promisify(execFile);

test(
  "packed package imports in a genuinely isolated JavaScript consumer",
  { timeout: 30000 },
  async (t) => {
    const directory = await mkdtemp(join(tmpdir(), "axo-protocol-package-"));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const consumer = join(directory, "consumer");
    await mkdir(consumer);
    // npm walks to an ancestor project without this manifest. Assert the boundary before install.
    await writeFile(
      join(consumer, "package.json"),
      JSON.stringify({
        name: "isolated-protocol-consumer",
        private: true,
        type: "module",
      }),
    );
    const prefix = await execute("npm", ["prefix"], { cwd: consumer });
    assert.equal(
      await realpath(prefix.stdout.trim()),
      await realpath(consumer),
    );
    const root = fileURLToPath(new URL("../", import.meta.url));
    await execute(
      "npm",
      ["pack", "--pack-destination", directory, "--ignore-scripts"],
      { cwd: root, maxBuffer: 65536 },
    );
    await execute(
      "npm",
      [
        "install",
        "--offline",
        "--ignore-scripts",
        join(directory, "axo-protocol-0.1.0.tgz"),
      ],
      { cwd: consumer, maxBuffer: 65536 },
    );
    const script = `import { createProfileServer, serveProfileMessage } from "@axo/protocol";
    const server = createProfileServer(); server.addMethod("echo", params => params);
    const reply = await serveProfileMessage(server, JSON.stringify([{jsonrpc:"2.0",id:"packed",method:"echo",params:{ok:true}}]), undefined);
    if (!Array.isArray(reply) || reply[0].result.ok !== true) throw Error("Package ABI failure");
    console.log("Packed package exports/runtime OK");`;
    const result = await execute(
      process.execPath,
      ["--input-type=module", "-e", script],
      { cwd: consumer },
    );
    assert.match(result.stdout, /Packed package exports\/runtime OK/);
  },
);
