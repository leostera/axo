import { build } from "esbuild";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { generateKeyPair, SignJWT } from "jose";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
export { Peer } from "../testing/client";

export const root = fileURLToPath(new URL("../../../", import.meta.url));
export const issuer = "https://private-test.cloudflareaccess.com";
export const testSessionSecret = "isolated-axo-test-session-secret-at-least-32-bytes";

export type AccountSession = {
  accountId: string;
  /** Headers for reads and the client WebSocket. */
  headers: Record<string, string>;
  /** Headers for cookie-authenticated mutations (adds the CSRF token). */
  mutationHeaders: Record<string, string>;
};

/**
 * Signs a person in to a fresh account without the Cloudflare OAuth round trip: seals a web
 * session cookie and seeds its digest in the account Durable Object. The harness must be
 * started with `SESSION_SECRET: testSessionSecret`. When the Worker moves to Access-verified
 * identity (RFD0013 gap plan, G1), only this function changes.
 */
export async function signIn(
  h: { url: string; mf: Miniflare },
  accountId: string = crypto.randomUUID(),
): Promise<AccountSession> {
  const { hmac, randomToken, sealCookie } = await import("../src/auth/crypto");
  const sessionId = randomToken();
  const csrf = randomToken();
  const expiresAt = Date.now() + 60 * 60 * 1000;
  const cookie = `__Host-axo_session=${await sealCookie(testSessionSecret, "web-session", { accountId, sessionId, csrf, expiresAt })}`;
  // The first request constructs the account Durable Object and its schema before seeding.
  const initialized = await fetch(new URL("api/v1/account/hosts", h.url), { headers: { Cookie: cookie } });
  if (initialized.status !== 401) throw new Error(`expected an unseeded session to be refused, got ${initialized.status}`);
  const storage = await h.mf.unsafeGetDurableObjectStorage("api-test", "AxoAccountDirectory", { name: accountId });
  await storage.exec("INSERT INTO profile (singleton, email, name) VALUES (1, ?, ?)", "test@example.test", "Test account");
  await storage.exec(
    "INSERT INTO web_sessions (session_digest, created_at, expires_at, revoked_at) VALUES (?, ?, ?, NULL)",
    await hmac(testSessionSecret, `session\0${sessionId}`),
    Date.now(),
    expiresAt,
  );
  const headers = { Cookie: cookie, Origin: "https://axo.leostera.dev" };
  return { accountId, headers, mutationHeaders: { ...headers, "X-Axo-CSRF": csrf } };
}
export async function harness(configuration: { audience?: string; bindings?: Record<string, string> } = {}) {
  const audience = configuration.audience ?? "private-test";
  const directory = await mkdtemp(join(tmpdir(), "axo-api-"));
  const bundle = join(directory, "worker.mjs");
  await build({
    entryPoints: [resolve(root, "packages/axo-api-worker/src/index.ts")],
    outfile: bundle,
    bundle: true,
    format: "esm",
    platform: "neutral",
    mainFields: ["module", "main"],
    external: ["cloudflare:workers"],
  });
  const keys = await generateKeyPair("RS256");
  const options = convertV4MiniflareOptions({
    name: "api-test",
    bindings: configuration.bindings ?? {},
    modules: true,
    script: await readFile(bundle, "utf8"),
    compatibilityDate: "2026-10-09",
    compatibilityFlags: ["nodejs_compat", "enable_ctx_exports"],
    exports: {
      AxoHostDirectory: { type: "durable-object", storage: "sqlite" },
      AxoHostRelay: { type: "durable-object", storage: "sqlite" },
      AxoIdentityIndex: { type: "durable-object", storage: "sqlite" },
      AxoAccountDirectory: { type: "durable-object", storage: "sqlite" },
      AxoPairingIndex: { type: "durable-object", storage: "sqlite" },
      AxoPairingRateLimit: { type: "durable-object", storage: "sqlite" },
      AxoSessionDO: { type: "durable-object", storage: "sqlite" },
    },
    durableObjects: {
      TEST_DIRECTORY: { className: "AxoHostDirectory", useSQLite: true },
      TEST_MACHINE: { className: "AxoHostRelay", useSQLite: true },
      TEST_IDENTITIES: { className: "AxoIdentityIndex", useSQLite: true },
      TEST_ACCOUNTS: { className: "AxoAccountDirectory", useSQLite: true },
      TEST_PAIRINGS: { className: "AxoPairingIndex", useSQLite: true },
      TEST_PAIRING_LIMITS: { className: "AxoPairingRateLimit", useSQLite: true },
      TEST_SESSION_HISTORY: { className: "AxoSessionDO", useSQLite: true },
    },
    resourcePersistencePath: join(directory, "storage"),
    unsafeInspectDurableObjects: true,
  });
  let mf = new Miniflare(options);
  let url: string;
  try {
    url = String(await mf.ready);
  } catch (error) {
    await mf.dispose();
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
  async function token(
    role: "client" | "daemon",
    overrides: Record<string, unknown> = {},
    expiration: string | number = "5m",
  ) {
    return new SignJWT({
      type: "app",
      ...(role === "client"
        ? { email: "human@example.com", sub: "human-subject" }
        : { common_name: "daemon.access", sub: "" }),
      ...overrides,
    })
      .setProtectedHeader({ alg: "RS256" })
      .setIssuer(issuer)
      .setAudience(audience)
      .setExpirationTime(expiration)
      .sign(keys.privateKey);
  }
  async function list(assertion: string) {
    const response = await fetch(`${url}v1/rpc`, {
      method: "POST",
      headers: { "Cf-Access-Jwt-Assertion": assertion },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "discover",
        method: "axo.machine.list",
        params: {},
      }),
    });
    if (response.status !== 200)
      throw new Error(`Discovery HTTP ${response.status}`);
    return (await response.json()) as {
      result: {
        machines: Array<{
          machineId: string;
          label: string;
          online: boolean;
          hostGeneration: string | null;
        }>;
      };
    };
  }
  return {
    get mf() {
      return mf;
    },
    get url() {
      return url;
    },
    token,
    list,
    async restart() {
      await mf.dispose();
      mf = new Miniflare(options);
      url = String(await mf.ready);
    },
    async close() {
      await mf.dispose();
      await rm(directory, { recursive: true, force: true });
    },
  };
}
