// Runtime dependency discovery: the user's ambient Pi, never a repo/bundled fallback.
import { access, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import { delimiter, isAbsolute, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { PiFailure } from "./process.ts";

const developmentDependencies = fileURLToPath(new URL("../../node_modules/", import.meta.url));

export class AmbientPi {
  private constructor(readonly executable: string, readonly version: string) { Object.freeze(this); }

  static async find(options: { path?: string; executable?: string; env?: NodeJS.ProcessEnv } = {}): Promise<AmbientPi> {
    const selectedExecutable = options.executable;
    const path = options.path ?? options.env?.PATH ?? process.env.PATH ?? "";
    const env = Object.freeze({ ...(options.env ?? process.env) });
    if (selectedExecutable !== undefined && (isDevelopmentBin(selectedExecutable) || normalize(selectedExecutable).startsWith(developmentDependencies))) {
      throw new PiFailure("rejected", "Repository-local Pi cannot be the runtime dependency");
    }
    const paths = selectedExecutable === undefined
      ? path.split(delimiter).filter(directory =>
          isAbsolute(directory) && !isDevelopmentBin(directory),
        ).slice(0, 256).map(directory => join(directory, "pi"))
      : [selectedExecutable];
    for (const executable of paths) {
      if (!isAbsolute(executable) || executable.length > 16384 || isDevelopmentBin(executable)) continue;
      try { await access(executable, constants.X_OK); } catch { continue; }
      // Keep the discovered launch path, including normal user/package-manager symlinks.
      // Resolving it for execution could bypass a legitimate ambient launcher.
      let resolved: string;
      try { resolved = await realpath(executable); }
      catch { throw new PiFailure("rejected", "Ambient Pi changed during discovery"); }
      if (normalize(executable).startsWith(developmentDependencies) || resolved.startsWith(developmentDependencies)) throw new PiFailure("rejected", "Repository-local Pi cannot be the runtime dependency");
      const version = await probe(executable, env);
      // Baseline for documented dispositions/settlement/canonical-entry RPCs, not an exact pin.
      const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
      if (!match || Number(match[1]) < 1 || (Number(match[1]) === 1 && Number(match[2]) < 1)) {
        throw new PiFailure("rejected", "Ambient Pi is unsupported: RPC lifecycle support requires Pi 1.1.0 or newer");
      }
      return new AmbientPi(executable, version);
    }
    throw new PiFailure("rejected", "Ambient Pi is missing: install Pi or configure its absolute executable; no bundled fallback");
  }
}
function isDevelopmentBin(path: string): boolean {
  return /(?:^|\/)node_modules\/\.bin(?:\/|$)/.test(normalize(path));
}
function probe(executable: string, env: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(executable, ["--version"], { env, timeout: 2500, maxBuffer: 4096, encoding: "utf8" }, (error, stdout) => {
      if (error) reject(new PiFailure("rejected", "Ambient Pi capability/version probe failed"));
      else resolve(stdout.trim());
    });
  });
}
