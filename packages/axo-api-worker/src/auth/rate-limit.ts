import type { AuthExports } from "./account-access";

export const RATE_WINDOW_MS = 60_000;

/** One attempt against the named limit: allowed, limited, or the limiter is down. */
export async function attempt(
  exports: AuthExports,
  name: string,
  now: number,
  maximum: number,
  windowMs: number = RATE_WINDOW_MS,
): Promise<"allowed" | "limited" | "unavailable"> {
  if (!exports.AxoPairingRateLimit) return "unavailable";
  try {
    const allowed = await exports.AxoPairingRateLimit.getByName(name).consume(now, windowMs, maximum);
    return allowed ? "allowed" : "limited";
  } catch {
    return "unavailable";
  }
}
