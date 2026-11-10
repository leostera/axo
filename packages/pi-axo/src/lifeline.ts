import { Socket } from "node:net";

/**
 * The lifeline (RFD0041): axod hands every Pi it starts the read end of a pipe whose write end
 * only axod holds. Its end of file means axod has gone, however it went, and Pi goes with it.
 * The descriptor is a pipe, read without a thread through a socket handle, and it never keeps
 * Pi's event loop alive by itself.
 */
export function watchLifeline(environment: NodeJS.ProcessEnv, onEnd: () => void): boolean {
  const value = environment.AXO_LIFELINE_FD;
  if (value === undefined || !/^[0-9]+$/u.test(value)) return false;
  const fd = Number(value);
  if (!Number.isSafeInteger(fd) || fd < 3) return false;
  let lifeline: Socket;
  try {
    lifeline = new Socket({ fd, readable: true, writable: false });
  } catch {
    return false;
  }
  let ended = false;
  const end = () => {
    if (ended) return;
    ended = true;
    onEnd();
  };
  lifeline.on("data", () => {});
  lifeline.on("end", end);
  lifeline.on("close", end);
  lifeline.on("error", end);
  lifeline.unref();
  return true;
}

/** What Pi does when axod has gone: stop as it stops on SIGTERM, and exit if that hangs. */
export function exitWithAxod(): void {
  setTimeout(() => process.exit(0), 3000).unref();
  process.kill(process.pid, "SIGTERM");
}
