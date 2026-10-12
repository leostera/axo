import { build } from "esbuild";
import {
  Miniflare,
  Response as MockResponse,
  convertV4MiniflareOptions,
} from "miniflare";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
export { Peer } from "../testing/client";

export const root = fileURLToPath(new URL("../../../", import.meta.url));
export const issuer = "https://private-test.cloudflareaccess.com";
export async function harness(configuration: { audience?: string } = {}) {
  const audience = configuration.audience ?? "private-test";
  const directory = await mkdtemp(join(tmpdir(), "axo-api-"));
  const bundle = join(directory, "worker.mjs");
  await build({
    entryPoints: [resolve(root, "sites/api.axo.leostera.dev/src/index.ts")],
    outfile: bundle,
    bundle: true,
    format: "esm",
    platform: "neutral",
    mainFields: ["module", "main"],
    external: ["cloudflare:workers"],
  });
  const keys = await generateKeyPair("RS256", { extractable: true });
  const jwk = {
    ...(await exportJWK(keys.publicKey)),
    kid: "test-key",
    alg: "RS256",
    use: "sig",
  };
  const options = convertV4MiniflareOptions({
    name: "api-test",
    modules: true,
    script: await readFile(bundle, "utf8"),
    compatibilityDate: "2026-10-09",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: {
      TEST_DIRECTORY: { className: "AxoHostDirectory", useSQLite: true },
      TEST_MACHINE: { className: "AxoHostRelay", useSQLite: true },
    },
    resourcePersistencePath: join(directory, "storage"),
    unsafeInspectDurableObjects: true,
    outboundService: async (request) => {
      if (request.url !== `${issuer}/cdn-cgi/access/certs`)
        return new MockResponse("Unexpected outbound request", { status: 403 });
      return MockResponse.json({ keys: [jwk] });
    },
    bindings: {
      ACCESS_TEAM_URL: issuer,
      ACCESS_AUD: audience,
      ACCESS_USER_EMAIL: "human@example.com",
      ACCESS_HOST_CLIENT_ID: "daemon.access",
    },
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
      .setProtectedHeader({ alg: "RS256", kid: "test-key" })
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
