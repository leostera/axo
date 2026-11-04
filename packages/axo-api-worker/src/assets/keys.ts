/** Where an account's asset lives in R2: under the account's own prefix, never shared (RFD0030). */
export function assetKey(accountId: string, hash: string): string {
  return `accounts/${accountId}/${hash}`;
}

/** The Cache-Tag one asset's cached reads carry, so a delete purges exactly them. */
export function assetCacheTag(accountId: string, hash: string): string {
  return `asset-${accountId}-${hash}`;
}

/** The Cache-Tag every cached read of an account carries. */
export function accountCacheTag(accountId: string): string {
  return `assets-${accountId}`;
}

/** The AxoAssetsDO that holds one account's assets. */
export function assetsDOName(accountId: string): string {
  return `account:${accountId}`;
}
