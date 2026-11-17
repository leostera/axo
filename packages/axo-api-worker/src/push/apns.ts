import { importPKCS8, SignJWT } from "jose";
import { z } from "zod";

/** Topics are installed identities, not aliases. Never send an old-ID token to the new topic. */
export const apnsTopicSchema = z.enum(["dev.leostera.axo.phone", "dev.leostera.axo"]);
export const apnsEnvironmentSchema = z.enum(["sandbox", "production"]);
export const apnsDestinationSchema = z.strictObject({
  topic: apnsTopicSchema,
  environment: apnsEnvironmentSchema,
  // Apple specifies opaque token data, not a fixed byte count. Bound our input without assuming 32 bytes.
  token: z.string().min(2).max(2048).regex(/^(?:[a-f0-9]{2})+$/i).transform((token) => token.toLowerCase()),
}).readonly().brand<"ApnsDestination">();
export type ApnsDestination = z.infer<typeof apnsDestinationSchema>;

const routeSchema = z.strictObject({
  accountId: z.uuid(), hostId: z.uuid(), sessionId: z.uuid(), requestId: z.uuid(),
});

/** Built from authoritative pending state, never from agent-provided notification text. */
export class ApnsRequestNotice {
  readonly #route: z.infer<typeof routeSchema>;
  readonly expiresAt: number;

  constructor(route: unknown, expiresAt: number) {
    this.#route = routeSchema.parse(route);
    if (!Number.isSafeInteger(expiresAt) || expiresAt <= 0) throw new Error("Invalid push expiry");
    this.expiresAt = expiresAt;
  }

  get collapseId(): string { return this.#route.requestId.toLowerCase(); }

  /** No question, field value, transcript, device proof or approval action enters this payload. */
  get body(): string {
    return JSON.stringify({
      aps: {
        alert: { title: "Axo", body: "A request needs your attention." },
        sound: "default",
        "thread-id": "axo.requests",
      },
      axo: { version: 1, ...this.#route },
    });
  }
}

const reasonSchema = z.enum([
  "BadCollapseId", "BadDeviceToken", "BadExpirationDate", "BadMessageId", "BadPriority", "BadTopic",
  "DeviceTokenNotForTopic", "DuplicateHeaders", "IdleTimeout", "InvalidPushType", "InvalidProviderToken",
  "MissingDeviceToken", "MissingTopic", "PayloadEmpty", "TopicDisallowed", "BadCertificate",
  "BadCertificateEnvironment", "ExpiredProviderToken", "Forbidden", "MissingProviderToken",
  "UnrelatedKeyIdInToken", "BadEnvironmentKeyIdInToken", "BadPath", "MethodNotAllowed", "ExpiredToken",
  "Unregistered", "PayloadTooLarge", "TooManyProviderTokenUpdates", "TooManyRequests", "InternalServerError",
  "ServiceUnavailable", "Shutdown",
]);
type Reason = z.infer<typeof reasonSchema> | "Unknown";

export type ApnsResult =
  | { kind: "accepted"; apnsId: string }
  | { kind: "expired" }
  | { kind: "cancelled" }
  | { kind: "scope-mismatch" }
  | { kind: "invalid-token"; reason: Reason; invalidatedAt: number | null }
  | { kind: "deferred"; reason: Reason; notBefore: number }
  | { kind: "rejected"; status: number; reason: Reason }
  // A failed/aborted transport may have reached Apple. This is not permission to replay.
  | { kind: "uncertain" };

export interface ApnsCredentials {
  teamId: string;
  keyId: string;
  privateKey: string;
  environment: z.infer<typeof apnsEnvironmentSchema>;
  topics: ReadonlyArray<z.infer<typeof apnsTopicSchema>>;
}

type ProviderScope = Omit<ApnsCredentials, "privateKey">;
type Transport = (url: string, init: RequestInit) => Promise<Response>;
const identifier = z.string().regex(/^[A-Z0-9]{10}$/);
const CACHE_SECONDS = 45 * 60;

/**
 * One bounded attempt, with injectable transport/clock. It neither enrolls devices nor grants authority.
 * Keep the instance alive to reuse its provider JWT. Real Workers-to-APNs HTTP/2 needs deployed validation.
 */
export class ApnsProvider {
  readonly #key: CryptoKey;
  readonly #teamId: string;
  readonly #keyId: string;
  readonly #environment: z.infer<typeof apnsEnvironmentSchema>;
  readonly #topics: ReadonlySet<string>;
  readonly #transport: Transport;
  readonly #now: () => number;
  #cached: { token: string; issuedAt: number } | undefined;
  #signing: Promise<string> | undefined;

  private constructor(credentials: ProviderScope, key: CryptoKey, transport: Transport, now: () => number) {
    this.#key = key;
    this.#teamId = credentials.teamId;
    this.#keyId = credentials.keyId;
    this.#environment = credentials.environment;
    this.#topics = new Set(credentials.topics);
    this.#transport = transport;
    this.#now = now;
  }

  static async create(credentials: ApnsCredentials, effects: { transport?: Transport; now?: () => number } = {}): Promise<ApnsProvider> {
    const scope: ProviderScope = {
      teamId: identifier.parse(credentials.teamId), keyId: identifier.parse(credentials.keyId),
      environment: apnsEnvironmentSchema.parse(credentials.environment),
      topics: z.array(apnsTopicSchema).min(1).max(2).parse(credentials.topics),
    };
    let key: CryptoKey;
    try { key = await importPKCS8(credentials.privateKey, "ES256"); }
    catch { throw new Error("APNs provider key could not be imported"); }
    return new ApnsProvider(scope, key, effects.transport ?? ((url, init) => fetch(url, init)), effects.now ?? Date.now);
  }

  async send(destination: ApnsDestination, notice: ApnsRequestNotice, signal?: AbortSignal): Promise<ApnsResult> {
    if (destination.environment !== this.#environment || !this.#topics.has(destination.topic)) return { kind: "scope-mismatch" };
    if (signal?.aborted) return { kind: "cancelled" };
    if (this.expired(notice)) return { kind: "expired" };
    const token = await this.providerToken();
    if (signal?.aborted) return { kind: "cancelled" };
    if (this.expired(notice)) return { kind: "expired" };
    const apnsId = crypto.randomUUID();
    const host = this.#environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const timeout = AbortSignal.timeout(10_000);
    const bounded = signal ? AbortSignal.any([timeout, signal]) : timeout;
    try {
      const response = await this.#transport(`https://${host}/3/device/${destination.token}`, {
        method: "POST", redirect: "error", signal: bounded,
        headers: {
          authorization: `bearer ${token}`, "content-type": "application/json",
          "apns-topic": destination.topic, "apns-push-type": "alert", "apns-priority": "10",
          "apns-expiration": String(Math.floor(notice.expiresAt / 1000)),
          "apns-collapse-id": notice.collapseId, "apns-id": apnsId,
        },
        body: notice.body,
      });
      if (response.status === 200) {
        try { await response.body?.cancel(); } catch { /* Cleanup cannot erase known acceptance. */ }
        // This is Apple's acceptance, not a delivery receipt or exactly-once guarantee.
        return { kind: "accepted", apnsId };
      }
      const feedback = await readFeedback(response, bounded);
      if (bounded.aborted) return { kind: "uncertain" };
      if ((response.status === 410 && (feedback.reason === "Unregistered" || feedback.reason === "ExpiredToken"))
        || (response.status === 400 && (feedback.reason === "BadDeviceToken" || feedback.reason === "DeviceTokenNotForTopic"))) {
        // The owner must still compare registration generation and Apple's invalidation timestamp.
        return { kind: "invalid-token", ...feedback };
      }
      if (response.status >= 500 && response.status <= 599) {
        return { kind: "deferred", reason: feedback.reason, notBefore: this.#now() + 15 * 60_000 };
      }
      if (response.status === 429 && feedback.reason === "TooManyRequests") {
        return { kind: "deferred", reason: feedback.reason, notBefore: this.#now() + 60_000 };
      }
      return { kind: "rejected", status: response.status, reason: feedback.reason };
    } catch {
      // Fetch errors can include the token-bearing URL. Never return/log the exception or retry here.
      return { kind: "uncertain" };
    }
  }

  private expired(notice: ApnsRequestNotice): boolean {
    return Math.floor(notice.expiresAt / 1000) <= Math.floor(this.#now() / 1000);
  }

  private async providerToken(): Promise<string> {
    const now = Math.floor(this.#now() / 1000);
    if (this.#cached && now >= this.#cached.issuedAt && now - this.#cached.issuedAt < CACHE_SECONDS) return this.#cached.token;
    if (this.#signing) return this.#signing;
    const signing = new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: this.#keyId })
      .setIssuer(this.#teamId).setIssuedAt(now).sign(this.#key)
      .then((token) => { this.#cached = { token, issuedAt: now }; return token; });
    this.#signing = signing;
    try { return await signing; }
    finally { if (this.#signing === signing) this.#signing = undefined; }
  }
}

/** Bound response allocation, and do not reflect arbitrary provider text into logs or the caller. */
async function readFeedback(response: Response, signal: AbortSignal): Promise<{ reason: Reason; invalidatedAt: number | null }> {
  const unknown = { reason: "Unknown" as const, invalidatedAt: null };
  if (!response.body) return unknown;
  const reader = response.body.getReader();
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > 4096) { await reader.cancel(); return unknown; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const value = JSON.parse(new TextDecoder().decode(bytes)) as { reason?: unknown; timestamp?: unknown };
    const parsed = reasonSchema.safeParse(value.reason);
    return {
      reason: parsed.success ? parsed.data : "Unknown",
      invalidatedAt: typeof value.timestamp === "number" && Number.isSafeInteger(value.timestamp) && value.timestamp >= 0 ? value.timestamp : null,
    };
  } catch { return unknown; }
  finally { signal.removeEventListener("abort", abort); reader.releaseLock(); }
}
