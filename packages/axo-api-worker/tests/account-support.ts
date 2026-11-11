import assert from "node:assert/strict";
import { randomToken } from "../src/auth/crypto";
import { Peer } from "../testing/client";
import { hostPairingCreateResultSchema, hostPairingRedeemResultSchema } from "@axo/protocol/v1";
import { Pi3Transcript, type AppendRecord, type ManifestRow, type SessionMetadata } from "@axo/protocol";
import type { AccountSession, Harness } from "./harness";

export type PairedHost = {
  hostId: string;
  hostGeneration: string;
  credentialId: string;
  credential: string;
  label: string;
};

/** Pairs a new host with the account, as a Mac redeeming a code from the web app does. */
export async function pairHost(h: Harness, session: AccountSession, label = "Test Mac"): Promise<PairedHost> {
  const created = await fetch(new URL("api/v1/account/host-pairings", h.url), { method: "POST", headers: session.headers });
  assert.equal(created.status, 200);
  const { code } = hostPairingCreateResultSchema.parse(await created.json());
  const host = {
    hostId: crypto.randomUUID(),
    hostGeneration: crypto.randomUUID(),
    credentialId: crypto.randomUUID(),
    credential: randomToken(),
    label,
  };
  const redeemed = await fetch(new URL("api/v1/host-pairings/redeem", h.url), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code, ...host, hostKind: "macos" }),
  });
  assert.equal(redeemed.status, 200);
  assert.equal(hostPairingRedeemResultSchema.parse(await redeemed.json()).hostId, host.hostId);
  return host;
}

/** The host's socket, negotiated and registered, as axod opens it. */
export async function connectHost(
  h: Harness, session: AccountSession, host: PairedHost, registration: Record<string, unknown> = {},
): Promise<Peer> {
  const daemon = await Peer.connectHostDaemon(h.url, session.accountId, host.hostId, {
    Authorization: `Bearer ${host.credential}`,
    "X-Axo-Credential-Id": host.credentialId,
  });
  await daemon.negotiate();
  const registered = await daemon.call("axo.host.register", {
    protocolVersion: 2,
    hostId: host.hostId,
    hostGeneration: host.hostGeneration,
    label: host.label,
    hostKind: "macos",
    sessions: [],
    ...registration,
  });
  assert.ok("result" in registered, JSON.stringify(registered));
  return daemon;
}

/** A client's one socket, after `axo.client.hello`. */
export async function connectClient(h: Harness, session: AccountSession, clientId = `tab-${crypto.randomUUID()}`) {
  const client = await Peer.connectClient(h.url, clientId, session.headers);
  const hello = await client.call("axo.client.hello", { protocolVersion: 2, clientId });
  assert.ok("result" in hello, JSON.stringify(hello));
  return { client, clientId, hello: hello.result as { hosts: Array<{ hostId: string; label: string; online: boolean }>; sessions: Array<{ sessionId: string; head: number; epoch: number | null; metadata: SessionMetadata }> } };
}

export function metadata(overrides: Partial<SessionMetadata> = {}): SessionMetadata {
  return { name: "A chat", emoji: null, folderName: "project", hasAgent: true, createdAt: 1_700_000_000, lastMessageAt: null, archived: false, ...overrides };
}

/** A Pi transcript the test writes line by line, hashed as axod hashes it. */
export class FakeTranscript {
  private constructor(readonly sessionId: string, readonly transcript: Pi3Transcript) {}

  static async create(sessionId: string = crypto.randomUUID()): Promise<FakeTranscript> {
    return new FakeTranscript(sessionId, await Pi3Transcript.start(JSON.stringify({ type: "session", version: 3, id: sessionId, timestamp: "2026-10-30T00:00:00.000Z", cwd: "/tmp" })));
  }

  /** Adds Pi entries; each names the previous one as its parent. */
  async write(...entries: Array<Record<string, unknown>>): Promise<void> {
    for (const entry of entries) {
      const parentId = this.transcript.records.at(-1)?.id ?? null;
      const line = JSON.stringify({ id: crypto.randomUUID().slice(0, 8), parentId, timestamp: "2026-10-30T00:00:01.000Z", ...entry });
      assert.ok(await this.transcript.push(line));
    }
  }

  /** Records `from`..`to` (positions), as an append carries them. */
  records(from: number, to: number = this.transcript.count): AppendRecord[] {
    return this.transcript.records.slice(from - 1, to).map(({ id, line, hash }) => ({ id, line, hash }));
  }

  manifestRow(version = 1, overrides: Partial<SessionMetadata> = {}): ManifestRow {
    const { count, chain, heads } = this.transcript;
    return { sessionId: this.sessionId, metadataVersion: version, metadata: metadata(overrides), format: "pi/3", upload: { count, chain, heads } };
  }
}

export const userMessage = (text: string) => ({ type: "message", message: { role: "user", content: [{ type: "text", text }] } });
export const assistantMessage = (text: string) => ({ type: "message", message: { role: "assistant", content: [{ type: "text", text }] } });
