// Runtime dependency discovery: the user's ambient Pi, never a repo/bundled fallback.
import { access, realpath } from "node:fs/promises";
import { constants } from "node:fs";
import { delimiter, isAbsolute, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";

export class AmbientPiError extends Error {
  constructor(readonly code: "missing" | "invalidSelection" | "invalidVersion" | "probeFailed" | "changed", message: string) {
    super(message);
    this.name = "AmbientPiError";
  }
}

const developmentDependencies = fileURLToPath(new URL("../../node_modules/", import.meta.url));

export class AmbientPi {
  private constructor(readonly executable: string, readonly version: string) { Object.freeze(this); }

  static async find(options: { path?: string; executable?: string; env?: NodeJS.ProcessEnv } = {}): Promise<AmbientPi> {
    const selectedExecutable = options.executable;
    const path = options.path ?? options.env?.PATH ?? process.env.PATH ?? "";
    const env = Object.freeze({ ...(options.env ?? process.env) });
    if (selectedExecutable !== undefined && (isDevelopmentBin(selectedExecutable) || normalize(selectedExecutable).startsWith(developmentDependencies))) {
      throw new AmbientPiError("invalidSelection", "Repository-local Pi cannot be the runtime dependency");
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
      catch { throw new AmbientPiError("changed", "Ambient Pi changed during discovery"); }
      if (normalize(executable).startsWith(developmentDependencies) || resolved.startsWith(developmentDependencies)) throw new AmbientPiError("invalidSelection", "Repository-local Pi cannot be the runtime dependency");
      const version = await probe(executable, env);
      // Version is dependency metadata, not a claim of TUI-extension capabilities/readiness.
      if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) {
        throw new AmbientPiError("invalidVersion", "Ambient Pi version output is unsupported");
      }
      return new AmbientPi(executable, version);
    }
    throw new AmbientPiError("missing", "Ambient Pi is missing: install Pi or configure its absolute executable; no bundled fallback");
  }
}
function isDevelopmentBin(path: string): boolean {
  return /(?:^|\/)node_modules\/\.bin(?:\/|$)/.test(normalize(path));
}
function probe(executable: string, env: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(executable, ["--version"], { env, timeout: 2500, maxBuffer: 4096, encoding: "utf8" }, (error, stdout) => {
      if (error) reject(new AmbientPiError("probeFailed", "Ambient Pi version probe failed"));
      else resolve(stdout.trim());
    });
  });
}
