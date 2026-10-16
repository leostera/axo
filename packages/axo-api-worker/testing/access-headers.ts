/** The Access edge consumes the authorization cookie; the Worker validates its injected assertion.
 * Local runtime tests have no edge, so also provide the assertion header. Neither credential is logged.
 */
export function accessHeaders(assertion: string): Record<string, string> {
  if (
    !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(assertion) ||
    assertion.length > 8192
  )
    throw new Error("Invalid Access application token");
  return {
    Cookie: `CF_Authorization=${assertion}`,
    "Cf-Access-Jwt-Assertion": assertion,
  };
}
