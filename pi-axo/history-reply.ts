import { ControlFailure, type History } from "./control-protocol.ts";

// Leave room below the receiver's 4-MiB frame/queue boundary. An oversized
// read is a capacity rejection, never a reason to destroy a healthy channel.
const replyBytes = 3 * 1024 * 1024;
const maximumNodes = 65_536;
const maximumDepth = 64;

/** Only public session-manager data is encoded. No file reads or JSONL writes.
 * The replacer stops oversized strings, node counts and depth during encoding;
 * final UTF-8/escaping size is checked before any bytes reach the transport.
 * Temporary escaping expansion is bounded (at most six bytes per string unit).
 */
export function encodeHistoryReply(id: string, history: History): string {
  let remaining = replyBytes;
  let nodes = 0;
  const depths = new WeakMap<object, number>();
  const raw = JSON.stringify({ reply: { id, response: { history } } }, function (this: object, key: string, value: unknown) {
    remaining -= key.length + 1;
    if (++nodes > maximumNodes) throw new ControlFailure("capacity");
    if (typeof value === "string") remaining -= value.length;
    if (typeof value === "number") remaining -= 24;
    if (typeof value === "boolean" || value === null) remaining -= 5;
    if (remaining < 0) throw new ControlFailure("capacity");
    if (typeof value === "object" && value !== null) {
      const depth = (depths.get(this) ?? -1) + 1;
      if (depth > maximumDepth) throw new ControlFailure("capacity");
      depths.set(value, depth);
    }
    return value;
  }) + "\n";
  if (Buffer.byteLength(raw) > replyBytes) throw new ControlFailure("capacity");
  return raw;
}
