// Vite bundles the module graph; these named exports are the stable DO deployment identities.
export { default } from "./http/router";
export { AxoHostDirectory } from "./axo-host-directory";
export { AxoHostRelay } from "./axo-host-relay";
export { AxoIdentityIndex } from "./auth/account";
// Keep the Durable Object export name stable so existing account SQLite storage is reused.
export { AxoAccountManager as AxoAccountDirectory } from "./auth/account-manager";
export { AxoPairingIndex, AxoPairingRateLimit } from "./auth/pairing-directory";
