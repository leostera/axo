import type { Authorized, TokenSignIn } from "./app";

/**
 * How a token app's credential goes on each request (TokenSignIn.authorize). Most services take
 * one of these; one that signs every request (Kraken) writes its own.
 */

type Fields = Readonly<Record<string, string>>;

/** `Authorization: Bearer <field>`. */
export function bearer(field: string): TokenSignIn["authorize"] {
  return (fields: Fields): Authorized => ({ headers: { Authorization: `Bearer ${fields[field]}` } });
}

/** HTTP basic auth. Octopus Energy takes its API key as the user name with no password. */
export function basic(user: string, password: string | null): TokenSignIn["authorize"] {
  return (fields: Fields): Authorized => {
    const bytes = new TextEncoder().encode(`${fields[user]}:${password ? fields[password] : ""}`);
    return { headers: { Authorization: `Basic ${btoa(String.fromCharCode(...bytes))}` } };
  };
}

/** The field in a header of the service's own, such as `Auth-API-Token`. */
export function header(name: string, field: string): TokenSignIn["authorize"] {
  return (fields: Fields): Authorized => ({ headers: { [name]: fields[field]! } });
}
