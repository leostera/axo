/** Errors of a provider's sign-in (OAuth or device). */
export class OAuthError extends Error {}

/** The token endpoint answered: the grant is refused or the refresh token is spent. */
export class GrantRefused extends OAuthError {}
