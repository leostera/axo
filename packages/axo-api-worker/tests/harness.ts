import { build } from "esbuild";
import { Miniflare, Response as MiniflareResponse, convertV4MiniflareOptions } from "miniflare";
import { generateKeyPair, SignJWT } from "jose";
import { createHash, randomBytes } from "node:crypto";
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
  /** What a browser signed in through the Worker sends: the session cookie and the app's Origin. */
  headers: Record<string, string>;
};

export type NativeSession = {
  accountId: string;
  token: string;
  /** What the phone app sends: the bearer token, no cookie and no Origin. */
  headers: Record<string, string>;
};

const sha256 = (text: string) => createHash("sha256").update(text).digest("base64url");

/** A request source of its own, as Cloudflare's edge would report; limits count per source. */
export const newSource = (): Record<string, string> => ({
  "CF-Connecting-IP": `test-source-${randomBytes(8).toString("hex")}`,
});

export type StartedLogin = {
  /** Where the Worker sent the person: Cloudflare's authorization page. */
  location: URL;
  state: string;
  /** The PKCE challenge the Worker gave Cloudflare. */
  challenge: string;
  /** The Worker's flow cookie, which the browser returns on the callback. */
  loginCookie: string;
};

/** Begins sign-in like a browser or the app's web-auth sheet does. */
export async function startLogin(h: { url: string }, query = ""): Promise<StartedLogin> {
  const response = await fetch(new URL(`api/auth/cloudflare/start${query}`, h.url), { redirect: "manual", headers: newSource() });
  if (response.status !== 302) throw new Error(`sign-in did not start: HTTP ${response.status}`);
  const location = new URL(response.headers.get("location")!);
  return {
    location,
    state: location.searchParams.get("state")!,
    challenge: location.searchParams.get("code_challenge")!,
    loginCookie: cookiePair(response, "__Host-axo_login")!,
  };
}

/** The person approves at Cloudflare, which sends them back to the Worker with a code. */
export async function finishLogin(
  h: { url: string; provider: Provider },
  started: StartedLogin,
  identity: { sub: string; email?: string; name?: string },
  overrides: { state?: string; cookie?: string | null; code?: string } = {},
): Promise<Response> {
  const code = overrides.code ?? h.provider.approve(identity, started.challenge);
  const cookie = overrides.cookie === undefined ? started.loginCookie : overrides.cookie;
  return fetch(
    new URL(`api/auth/cloudflare/callback?code=${code}&state=${encodeURIComponent(overrides.state ?? started.state)}`, h.url),
    { redirect: "manual", headers: { ...newSource(), ...(cookie ? { Cookie: cookie } : {}) } },
  );
}

/** `name=value` of the Set-Cookie named `name`, or null. */
export function cookiePair(response: Response, name: string): string | null {
  for (const header of response.headers.getSetCookie()) {
    if (header.startsWith(`${name}=`)) {
      const pair = header.split(";")[0]!;
      return pair.slice(name.length + 1) === "" ? null : pair;
    }
  }
  return null;
}

/** Signs a person in on the web through the (simulated) Cloudflare OAuth provider. */
export async function signIn(
  h: { url: string; provider: Provider },
  subject: string = crypto.randomUUID(),
): Promise<AccountSession> {
  const started = await startLogin(h);
  const response = await finishLogin(h, started, { sub: subject, email: `${subject}@example.test`, name: "Test Person" });
  const cookie = cookiePair(response, "__Host-axo_session");
  if (response.status !== 302 || !cookie) throw new Error(`sign-in failed with HTTP ${response.status}`);
  const headers = { Cookie: cookie, Origin: APP_ORIGIN };
  const me = await fetch(new URL("api/auth/me", h.url), { headers });
  if (me.status !== 200) throw new Error(`sign-in did not take: HTTP ${me.status}`);
  return { accountId: ((await me.json()) as { accountId: string }).accountId, headers };
}

/** Signs a person in the way the phone app does: PKCE through the system browser, then a token. */
export async function signInNative(
  h: { url: string; provider: Provider },
  subject: string = crypto.randomUUID(),
): Promise<NativeSession> {
  const verifier = randomBytes(32).toString("base64url");
  const started = await startLogin(h, `?client=native&challenge=${sha256(verifier)}`);
  const callback = await finishLogin(h, started, { sub: subject, email: `${subject}@example.test` });
  const code = new URL(callback.headers.get("location")!).searchParams.get("code");
  if (callback.status !== 302 || !code) throw new Error(`native sign-in failed with HTTP ${callback.status}`);
  const response = await fetch(new URL("api/auth/token", h.url), {
    method: "POST",
    headers: newSource(),
    body: JSON.stringify({ code, verifier }),
  });
  if (response.status !== 200) throw new Error(`token exchange failed with HTTP ${response.status}`);
  const { token, accountId } = (await response.json()) as { token: string; accountId: string };
  return { accountId, token, headers: { Authorization: `Bearer ${token}` } };
}

/** The simulated Cloudflare OAuth provider the Worker talks to. */
export class Provider {
  private readonly grants = new Map<string, { identity: Record<string, unknown>; challenge: string; used: boolean }>();
  private readonly accessTokens = new Map<string, Record<string, unknown>>();
  private failure: "token" | "profile" | null = null;
  /** Every token request the Worker made, for assertions. */
  readonly tokenRequests: Array<{ authorization: string | null; form: URLSearchParams }> = [];

  /** Cloudflare would hand out a code for this person after they approve; with PKCE challenge `challenge`. */
  approve(identity: { sub: string; email?: string; name?: string }, challenge: string): string {
    const code = randomBytes(16).toString("hex");
    this.grants.set(code, { identity, challenge, used: false });
    return code;
  }

  failNext(stage: "token" | "profile"): void {
    this.failure = stage;
  }

  async handle(request: { url: string; method: string; headers: { get(name: string): string | null }; text(): Promise<string> }) {
    const json = (body: unknown, status = 200) =>
      new MiniflareResponse(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
    if (request.url === "https://dash.cloudflare.com/oauth2/token" && request.method === "POST") {
      const form = new URLSearchParams(await request.text());
      this.tokenRequests.push({ authorization: request.headers.get("authorization"), form });
      if (this.failure === "token") {
        this.failure = null;
        return json({ error: "server_error" }, 500);
      }
      const expected = `Basic ${Buffer.from("test-client:test-secret").toString("base64")}`;
      const grant = this.grants.get(form.get("code") ?? "");
      const verifier = form.get("code_verifier") ?? "";
      if (request.headers.get("authorization") !== expected || !grant || grant.used
        || form.get("grant_type") !== "authorization_code"
        || form.get("redirect_uri") !== "https://axo.leostera.dev/api/auth/cloudflare/callback"
        || sha256(verifier) !== grant.challenge) return json({ error: "invalid_grant" }, 400);
      grant.used = true;
      const accessToken = randomBytes(16).toString("hex");
      this.accessTokens.set(accessToken, grant.identity);
      return json({ access_token: accessToken, token_type: "bearer" });
    }
    if (request.url === "https://dash.cloudflare.com/oauth2/userinfo") {
      if (this.failure === "profile") {
        this.failure = null;
        return json({ error: "server_error" }, 500);
      }
      const identity = this.accessTokens.get(request.headers.get("authorization")?.replace("Bearer ", "") ?? "");
      return identity ? json(identity) : json({ error: "invalid_token" }, 401);
    }
    return new MiniflareResponse("unexpected outbound request", { status: 502 });
  }
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
  const provider = new Provider();
  const options = convertV4MiniflareOptions({
    name: "api-test",
    bindings: {
      OAUTH_CLIENT_ID: "test-client",
      OAUTH_CLIENT_SECRET: "test-secret",
      SESSION_SECRET: testSessionSecret,
      ...configuration.bindings,
    },
    // The Worker's only outbound requests are to the identity provider.
    outboundService: (request: Request) => provider.handle(request),
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
    provider,
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
