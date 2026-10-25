import { build } from "esbuild";
import { Miniflare, Response as MiniflareResponse, convertV4MiniflareOptions } from "miniflare";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
export { Peer } from "../testing/client";

export const root = fileURLToPath(new URL("../../../", import.meta.url));
export const issuer = "https://private-test.cloudflareaccess.com";
export const testSessionSecret = "isolated-axo-test-session-secret-at-least-32-bytes";

export const APP_ORIGIN = "https://axo.leostera.dev";

export type AccountSession = {
  accountId: string;
  /** What a browser on the app sends after passing Access: the Access assertion and the app's Origin. */
  headers: Record<string, string>;
};

/**
 * Signs a person in through (simulated) Cloudflare Access: mints an Access assertion for a new
 * subject with the harness's signing key, which the Worker verifies against the harness's
 * JWKS, then asks the Worker which account that person has.
 */
export async function signIn(
  h: { url: string; token: Harness["token"] },
  subject: string = crypto.randomUUID(),
): Promise<AccountSession> {
  const assertion = await h.token("client", { sub: subject, email: `${subject}@example.test` });
  const headers = { "Cf-Access-Jwt-Assertion": assertion, Origin: APP_ORIGIN };
  const response = await fetch(new URL("api/auth/me", h.url), { headers });
  if (response.status !== 200) throw new Error(`sign-in failed with HTTP ${response.status}`);
  const { accountId } = (await response.json()) as { accountId: string };
  return { accountId, headers };
}

export type Harness = Awaited<ReturnType<typeof harness>>;

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
  const keys = await generateKeyPair("RS256", { extractable: true });
  const keyId = "harness-key";
  const jwks = JSON.stringify({ keys: [{ ...(await exportJWK(keys.publicKey)), kid: keyId, alg: "RS256", use: "sig" }] });
  const options = convertV4MiniflareOptions({
    name: "api-test",
    bindings: {
      ACCESS_TEAM_DOMAIN: issuer,
      ACCESS_AUD: audience,
      SESSION_SECRET: testSessionSecret,
      ...configuration.bindings,
    },
    // The Worker's only outbound request is for Access's signing keys.
    outboundService: (request: { url: string }) =>
      request.url === `${issuer}/cdn-cgi/access/certs`
        ? new MiniflareResponse(jwks, { headers: { "Content-Type": "application/json" } })
        : new MiniflareResponse("unexpected outbound request", { status: 502 }),
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
      .setProtectedHeader({ alg: "RS256", kid: keyId })
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
