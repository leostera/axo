// Vite bundles the module graph; these named exports are the stable DO deployment identities.
export { default } from "./http/router";
export { AxoIdentityIndex } from "./auth/account";
// Keep the Durable Object export name stable so existing account SQLite storage is reused.
export { AxoAccountManager as AxoAccountDirectory } from "./auth/account-manager";
export { AxoPairingIndex, AxoPairingRateLimit } from "./auth/pairing-directory";
export { AxoSessionDO } from "./session-store";
export { AxoHostDO } from "./host-do";
export { AxoClientDO } from "./client-do";
export { AxoAssetsDO } from "./assets/assets-do";
export { AxoWhatsAppDO } from "./apps/whatsapp-do";
export { AxoAssetCache } from "./assets/cache";
