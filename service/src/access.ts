import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

export interface AccessPolicy {
  ACCESS_TEAM_URL: string;
  ACCESS_AUD: string;
  ACCESS_USER_EMAIL: string;
  ACCESS_HOST_CLIENT_ID: string;
}
export type ConnectionRole = "host" | "phone";
export interface Principal { role: ConnectionRole; expiresAt: number }

export async function authorize(
  request: Request, role: ConnectionRole, policy: AccessPolicy,
  keys: JWTVerifyGetKey = createRemoteJWKSet(new URL(`${policy.ACCESS_TEAM_URL}/cdn-cgi/access/certs`)),
): Promise<Principal> {
  const token = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!token || policy.ACCESS_AUD === "unconfigured") throw new Error("Access required");
  const { payload } = await jwtVerify(token, keys, {
    issuer: policy.ACCESS_TEAM_URL, audience: policy.ACCESS_AUD,
    algorithms: ["RS256"], requiredClaims: ["exp", "sub"],
  });
  if (payload.type !== "app") throw new Error("Application token required");
  // Access service tokens have an empty sub; common_name is their client ID.
  if (role === "host" && payload.common_name !== policy.ACCESS_HOST_CLIENT_ID) throw new Error("Host identity required");
  if (role === "phone" && (!payload.sub || payload.email !== policy.ACCESS_USER_EMAIL)) throw new Error("User identity required");
  return { role, expiresAt: payload.exp! * 1000 };
}
