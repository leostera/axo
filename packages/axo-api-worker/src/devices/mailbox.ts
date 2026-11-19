import { z } from "zod";

const key = z.string().length(88).regex(/^[A-Za-z0-9+/]+={0,2}$/);
export const linkCandidateSchema = z.strictObject({
  accountId: z.uuid(), id: z.uuid(), expiresAt: z.number().int().positive(), key,
  name: z.string().min(1).max(80).refine(value => value.trim() === value && !/[\u0000-\u001f\u007f-\u009f]/u.test(value)),
  signature: key,
});
export const deviceMailboxCommandSchema = z.discriminatedUnion("operation", [
  z.strictObject({ operation: z.literal("create"), candidate: linkCandidateSchema }),
  z.strictObject({ operation: z.literal("poll"), id: z.uuid() }),
  z.strictObject({ operation: z.literal("cancel"), id: z.uuid() }),
  z.strictObject({ operation: z.literal("complete"), id: z.uuid(), box: z.string().min(40).max(6000).regex(/^[A-Za-z0-9+/]+={0,2}$/) }),
]);
type Owner = { accountId: string; sessionDigest: string };
type Row = { id: string; session_digest: string; expires_at: number; candidate_json: string; box: string | null; state: "waiting" | "complete" | "cancelled" };
type MailboxValue = { error: string } | { state: "waiting" | "complete" | "cancelled"; box?: string };

export function candidateMessage(candidate: z.infer<typeof linkCandidateSchema>): Uint8Array<ArrayBuffer> {
  return new TextEncoder().encode(`axo-link-recipient/v1\n${candidate.accountId}\n${candidate.id}\n${candidate.expiresAt}\n${candidate.key}\n${btoa(String.fromCharCode(...new TextEncoder().encode(candidate.name)))}`);
}

async function possessesKey(candidate: z.infer<typeof linkCandidateSchema>): Promise<boolean> {
  try {
    const bytes = (value: string) => Uint8Array.from(atob(value), char => char.charCodeAt(0));
    const publicKey = await crypto.subtle.importKey("raw", bytes(candidate.key), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, bytes(candidate.signature), candidateMessage(candidate));
  } catch { return false; }
}

/** An account-local blind mailbox. It never receives the QR secret and cannot make a grant. */
export class DeviceLinkMailboxes {
  constructor(private readonly storage: DurableObjectStorage, private readonly live: () => boolean) {
    storage.sql.exec(`CREATE TABLE IF NOT EXISTS device_link_mailboxes (
      id TEXT PRIMARY KEY, session_digest TEXT NOT NULL, expires_at INTEGER NOT NULL,
      candidate_json TEXT NOT NULL, box TEXT, state TEXT NOT NULL CHECK (state IN ('waiting', 'complete', 'cancelled')))`);
  }

  async command(owner: Owner, input: unknown): Promise<{ status: number; value: MailboxValue }> {
    if (!this.live()) return { status: 401, value: { error: "Sign-in required" } };
    const parsed = deviceMailboxCommandSchema.safeParse(input);
    if (!parsed.success) return { status: 400, value: { error: "Invalid device linking request" } };
    const command = parsed.data;
    const sql = this.storage.sql;
    const now = Date.now();
    sql.exec("DELETE FROM device_link_mailboxes WHERE expires_at<=?", now);
    if (command.operation === "create") {
      const candidate = command.candidate;
      if (candidate.accountId !== owner.accountId || candidate.expiresAt <= now || candidate.expiresAt > now + 300_000 || !await possessesKey(candidate))
        return { status: 400, value: { error: "Invalid device linking proof" } };
      // Proof verification awaits crypto; bounds and the claim are checked together afterward.
      return this.storage.transactionSync(() => {
        if (!this.live()) return { status: 401, value: { error: "Sign-in required" } };
        if (candidate.expiresAt <= Date.now()) return { status: 409, value: { error: "Linking code expired" } };
        const previous = sql.exec<Row>("SELECT * FROM device_link_mailboxes WHERE id=?", candidate.id).toArray()[0];
        if (previous) return previous.session_digest === owner.sessionDigest && previous.candidate_json === JSON.stringify(candidate)
          ? { status: 200, value: { state: previous.state } } : { status: 409, value: { error: "Linking request changed" } };
        const count = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM device_link_mailboxes").one().count;
        const own = sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM device_link_mailboxes WHERE session_digest=?", owner.sessionDigest).one().count;
        if (count >= 32 || own >= 4) return { status: 429, value: { error: "Too many linking requests" } };
        sql.exec("INSERT INTO device_link_mailboxes (id, session_digest, expires_at, candidate_json, state) VALUES (?, ?, ?, ?, 'waiting')",
          candidate.id, owner.sessionDigest, candidate.expiresAt, JSON.stringify(candidate));
        return { status: 200, value: { state: "waiting" } };
      });
    }
    const row = sql.exec<Row>("SELECT * FROM device_link_mailboxes WHERE id=?", command.id).toArray()[0];
    if (!row) return { status: 404, value: { error: "Linking request expired" } };
    if (command.operation === "complete") {
      if (row.session_digest === owner.sessionDigest) return { status: 403, value: { error: "Use an existing phone to link this device" } };
      if (row.state !== "waiting") return row.state === "complete" && row.box === command.box
        ? { status: 200, value: { state: "complete" } } : { status: 409, value: { error: "Linking already settled" } };
      sql.exec("UPDATE device_link_mailboxes SET state='complete', box=? WHERE id=?", command.box, command.id);
      return { status: 200, value: { state: "complete" } };
    }
    if (row.session_digest !== owner.sessionDigest) return { status: 404, value: { error: "Linking request not found" } };
    if (command.operation === "cancel") {
      if (row.state !== "waiting") return { status: 409, value: { error: "Linking already settled" } };
      sql.exec("UPDATE device_link_mailboxes SET state='cancelled' WHERE id=?", command.id);
      return { status: 200, value: { state: "cancelled" } };
    }
    return { status: 200, value: { state: row.state, ...(row.box ? { box: row.box } : {}) } };
  }
}
