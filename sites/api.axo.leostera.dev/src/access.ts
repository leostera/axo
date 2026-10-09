import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

export interface AccessPolicy {
  ACCESS_TEAM_URL: string;
  ACCESS_AUD: string;
  ACCESS_USER_EMAIL: string;
  ACCESS_HOST_CLIENT_ID: string;
}
export interface Principal {
  role: "client" | "daemon";
  identity: string;
  expiresAt: number;
}
export async function authorize(
  request: Request,
  role: Principal["role"],
  policy: AccessPolicy,
  keys?: JWTVerifyGetKey,
): Promise<Principal> {
  const issuer = new URL(policy.ACCESS_TEAM_URL);
  if (
    issuer.protocol !== "https:" ||
    issuer.pathname !== "/" ||
    issuer.username ||
    issuer.password ||
    !policy.ACCESS_AUD ||
    !policy.ACCESS_USER_EMAIL ||
    !policy.ACCESS_HOST_CLIENT_ID
  )
    throw new Error("Access configuration required");
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token) throw new Error("Access required");
  const { payload } = await jwtVerify(
    token,
    keys ?? createRemoteJWKSet(new URL("/cdn-cgi/access/certs", issuer)),
    {
      issuer: issuer.origin,
      audience: policy.ACCESS_AUD,
      algorithms: ["RS256"],
      requiredClaims: ["exp", "sub"],
    },
  );
  if (payload.type !== "app") throw new Error("Application token required");
  const identity = role === "daemon" ? payload.common_name : payload.sub;
  if (typeof identity !== "string" || !identity.length || identity.length > 256)
    throw new Error("Identity required");
  if (
    role === "daemon" &&
    (identity !== policy.ACCESS_HOST_CLIENT_ID ||
      payload.sub !== "" ||
      payload.email !== undefined)
  )
    throw new Error("Daemon role required");
  if (
    role === "client" &&
    (payload.email !== policy.ACCESS_USER_EMAIL ||
      payload.common_name !== undefined)
  )
    throw new Error("Client role required");
  return { role, identity, expiresAt: payload.exp! * 1000 };
}
