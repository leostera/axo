import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import { z } from "zod";

/**
 * People are authenticated by Cloudflare Access (RFD0013 gap plan, G1). Access sits in front of
 * `/app` and `/api/*`, signs every request it lets through with `Cf-Access-Jwt-Assertion`, and
 * the Worker verifies that assertion itself: signature against the team's keys, issuer,
 * audience and expiry. Nothing is trusted from the route, the hostname or the mere presence of
 * a header, so a request that reaches the Worker without passing Access is anonymous.
 *
 * Browsers present Access's cookie and native apps a `cf-access-token` header; Access turns
 * both into the same assertion, so the Worker has a single verification path.
 */
export const ACCESS_ASSERTION_HEADER = "Cf-Access-Jwt-Assertion";

export type AccessEnvironment = Env & {
  /** `https://<team>.cloudflareaccess.com`: the issuer and the origin of the signing keys. */
  ACCESS_TEAM_DOMAIN?: string;
  /** The Access application's audience tag; several may be listed, comma-separated. */
  ACCESS_AUD?: string;
};

export type AccessConfiguration = {
  readonly issuer: string;
  readonly audiences: readonly string[];
  readonly certsUrl: URL;
};

/** A person Access has authenticated. Service tokens are not people and never reach here. */
export type AccessIdentity = {
  readonly issuer: string;
  readonly subject: string;
  readonly email: string | null;
  /** Milliseconds since the epoch; long-lived connections must end by then. */
  readonly expiresAt: number;
};

const TEAM_DOMAIN = /^https:\/\/[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.cloudflareaccess\.com$/;
const AUDIENCE = /^[A-Za-z0-9_-]{1,128}$/;
const MAX_ASSERTION_BYTES = 8192;

export function parseAccessConfiguration(env: AccessEnvironment): AccessConfiguration | null {
  const issuer = env.ACCESS_TEAM_DOMAIN?.trim().replace(/\/$/, "") ?? "";
  const audiences = (env.ACCESS_AUD ?? "").split(",").map(value => value.trim()).filter(Boolean);
  if (!TEAM_DOMAIN.test(issuer) || audiences.length === 0 || !audiences.every(value => AUDIENCE.test(value)))
    return null;
  return { issuer, audiences, certsUrl: new URL("/cdn-cgi/access/certs", issuer) };
}

const personClaims = z.object({
  type: z.literal("app"),
  sub: z.string().min(1).max(512),
  email: z.string().min(3).max(320).optional(),
  exp: z.number().int().positive(),
});

const keySets = new Map<string, JWTVerifyGetKey>();
function keySetFor(configuration: AccessConfiguration): JWTVerifyGetKey {
  const key = configuration.certsUrl.href;
  let keySet = keySets.get(key);
  if (!keySet) {
    keySet = createRemoteJWKSet(configuration.certsUrl, { timeoutDuration: 5_000, cooldownDuration: 30_000 });
    keySets.set(key, keySet);
  }
  return keySet;
}

/** The verified person behind a request, or null for anything else (missing, forged, expired, wrong audience, service token). */
export async function verifyAccessIdentity(
  request: Request,
  configuration: AccessConfiguration,
  keySet: JWTVerifyGetKey = keySetFor(configuration),
): Promise<AccessIdentity | null> {
  const assertion = request.headers.get(ACCESS_ASSERTION_HEADER);
  if (!assertion || assertion.length > MAX_ASSERTION_BYTES) return null;
  try {
    const { payload } = await jwtVerify(assertion, keySet, {
      issuer: configuration.issuer,
      audience: [...configuration.audiences],
      algorithms: ["RS256"],
      requiredClaims: ["exp", "sub"],
    });
    const claims = personClaims.safeParse(payload);
    if (!claims.success) return null;
    return {
      issuer: configuration.issuer,
      subject: claims.data.sub,
      email: claims.data.email ?? null,
      expiresAt: claims.data.exp * 1000,
    };
  } catch {
    return null;
  }
}
