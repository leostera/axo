/**
 * Axo's apps (RFD0016, Apps): the services Axo provides itself, reached from a Session as
 * `codemode.apps.<app>.<tool>({ account, ... })`. This package is what each app is: its sign-in
 * (an OAuth provider's config, a token's fields, a device sign-in, a Mac program), its API's hosts,
 * and its tools. It holds no state and no credential: the account's gateway stores the grants and
 * clients, and makes every call with them through the `ProviderApi` a tool is given.
 */
export * from "./app";
export * from "./errors";
export { APP_DEFINITIONS, macCommand, toolsOf } from "./catalog";
export { requestTool } from "./request";
export { basic, bearer, header } from "./token";
export * from "./oauth/provider";
export { OAUTH_PROVIDER_CONFIGS } from "./oauth/providers";
export {
  DEVICE_CODE_LIFETIME_MS,
  DEVICE_VERIFICATION_URL,
  pollDeviceCode,
  refreshOpenAIGrant,
  requestDeviceCode,
  revokeOpenAIGrant,
  type DeviceCode,
  type OpenAIGrant,
} from "./oauth/openai";
