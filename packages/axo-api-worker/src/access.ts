export interface Principal {
  role: "client" | "daemon";
  identity: string;
  expiresAt: number;
}

// Cloudflare Access protects the Worker at the edge. The Worker deliberately does
// not require or validate an Access JWT; this identity only scopes relay roles.
const CONNECTION_LIFETIME_MS = 24 * 60 * 60 * 1000;

export function edgePrincipal(role: Principal["role"]): Principal {
  return {
    role,
    identity: `cloudflare-edge:${role}`,
    expiresAt: Date.now() + CONNECTION_LIFETIME_MS,
  };
}
