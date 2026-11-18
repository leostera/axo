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

/**
 * Where a request came from, for per-source limits: its IPv4 address, or its IPv6 /64. One host
 * on IPv6 commonly holds a whole /64, so keying on the full address would give it 2^64 sources.
 */
export function requestSource(request: Request): string {
  const address = request.headers.get("CF-Connecting-IP") ?? "";
  if (address.length === 0 || address.length > 64) return "unknown";
  return address.includes(":") ? ipv6Prefix64(address) ?? "unknown" : address;
}

/** The first four groups of an IPv6 address, expanded: `2001:db8::1` → `2001:db8:0:0::/64`. */
function ipv6Prefix64(address: string): string | null {
  const [head = "", tail, extra] = address.toLowerCase().split("::");
  if (extra !== undefined) return null;
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  // An embedded IPv4 tail takes two groups; it never reaches the first four.
  const width = (groups: string[]) => groups.reduce((n, group) => n + (group.includes(".") ? 2 : 1), 0);
  const missing = 8 - width(left) - width(right);
  if (tail === undefined ? missing !== 0 : missing < 1) return null;
  const groups = [...left, ...Array<string>(tail === undefined ? 0 : missing).fill("0"), ...right];
  const prefix = groups.slice(0, 4);
  if (prefix.length < 4 || !prefix.every((group) => /^[0-9a-f]{1,4}$/.test(group))) return null;
  return `${prefix.map((group) => group.replace(/^0+(?=.)/, "")).join(":")}::/64`;
}
