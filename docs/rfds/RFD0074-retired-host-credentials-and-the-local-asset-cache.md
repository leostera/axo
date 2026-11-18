# RFD0074 - Axo: retired host credentials and the local asset cache

- Feature Name: `retired-credentials-and-asset-cache`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Implementation design
- Amends: [RFD0013](RFD0013-axo-account-and-relay.md) (unlinking), [RFD0030](RFD0030-assets.md) (the Mac's copies)
- Related: [RFD0073](RFD0073-agents-vs-the-person-on-the-local-socket.md) (who may link a Mac)

## Summary

Two things a Mac kept after the account had stopped wanting them:

1. **Host credentials.** Unlinking a Mac, or linking it to another account, deleted the credential from the Keychain and told no one. The account kept the Mac listed as linked, and the credential's verifier stayed valid. If the Keychain refused the delete, which axod ignored, a working secret for the old account stayed on disk indefinitely. Now axod records each credential it stops using as **retired**, in the same database write that stops using it. It then revokes the credential at the account it belonged to, using the credential itself to authenticate, and only after that deletes it from the Keychain. If the Keychain refuses, axod says so and tries again.
2. **The asset cache.** `~/.axo/assets` only grew. When the person deleted an asset in the account, the Mac kept its copy. Now, while the Mac is connected, it checks its copies against the account and deletes the ones the account no longer has. That bounds the cache by the account's own quota, and it keeps every path a transcript points at for as long as the account keeps the asset.

## Who may link: RFD0073's rule, and its one exception

`axo.relay.link` hands this Mac to an account, so under RFD0073 only the person may call it, from Axo.app (`Signer::AxoApp`). Any other caller gets `-32012`. There is one exception. A relay endpoint on loopback (`localhost`, `127.0.0.1`, `::1`) may be linked by any local caller, because that account never leaves this Mac: it is a local Worker or an end-to-end test, run by someone already acting as the person. `axo.relay.unlink` stays open to every caller, because it only takes access away. RFD0073 does not list these, so they are recorded here.

**Linux is not covered yet.** It has no signed app, so axod cannot tell the person from an agent there. Today the CLI is the only way to pair a Linux host, and it may run in a Session's own pane. So on Linux, linking stays open to local callers, as it was before this change. Closing it needs a consent path in the Linux desktop (RFD0054), for example confirming the code in its settings window. That is left open here.

## Retired credentials

### The rule

A credential axod stops using is revoked at its account before its secret is deleted. Until both have happened, the credential stays on record.

- **Unlink:** the saved link moves its account credential into `retired` and clears the link, in one write. Then axod closes the socket and retires the credential.
- **Linking again:** a successful redemption saves the new link and moves the previous credential into `retired`, in one write. Then axod retires it. A re-link to the same account has already replaced the credential there, so the revocation is refused with `401`, which counts as done. A re-link to another account revokes the Mac in the old account, which then shows it as revoked, not as linked.
- **A pending redemption** that unlink abandons may already have been redeemed, but axod does not know for which account, so it cannot be revoked. Its secret is deleted. Only this Keychain ever held it, and the account it may have reached shows the Mac as never connecting.

### Retiring one credential

1. Read the secret from the Keychain. If the Keychain no longer has it, nothing can use or revoke it, so axod forgets the record.
2. `POST /api/v1/accounts/<account>/hosts/<host>/credential/revoke`, authenticated as the Mac's sockets are (`Authorization: Bearer <credential>`, `X-Axo-Credential-Id`).
   - **`204`:** the Worker checked that this is the host's current credential and revoked the host. Its sockets close (RFD0013, revocation).
   - **`401`:** the credential is no longer the host's, because it was replaced or revoked. Done.
   - **Anything else, or no answer:** keep the record and retry later.
3. Delete the secret from the Keychain. If that fails, keep the record, log `event=relay.credential_keychain_kept`, and return the failure. When the caller is unlink, it answers with an error that says the link is gone but the Keychain kept the secret. The secret is now revoked, so the error is about what is left on disk, not about access.
4. Forget the record.

### When it runs

It runs right after an unlink or a link, inside the same `link_operations` lock. It also runs at axod's start, and then hourly while any record is left, taking the same lock each time.

The lock matters. The Worker checks the credential and revokes the host in two steps. If a redemption for the same account ran between them, the revocation would remove the new link. Every redemption for this host comes from this axod, and runs under that lock, so the two never overlap.

### The Worker

The route lives in its own file, `http/host-credential.ts`. It checks the credential with `authorizeHost`, then calls `revokeHost`, the same call the person's revoke makes, so it needs no new account-manager code. It refuses any request with an `Origin` header, as the Mac's other routes do.

## The local asset cache

### Policy: mirror the account, don't evict

The Mac's copies are a cache of the account's assets, and the account already bounds them: 10 GiB and 10,000 assets (RFD0030). So the policy is that the Mac keeps a copy only while the account still has the asset. There is no least-recently-used eviction and no byte budget.

- **Why not evict:** Pi transcripts name files by path (`[Attached file: … at ~/.axo/assets/<hex>/<name> axo-asset:sha256:…]`). An agent that opens a path from an earlier turn gets `ENOENT` if the file has been evicted. Nothing refetches a path when it is opened. Eviction would break exactly the case the cache exists for.
- **What the person controls:** deleting an asset in Settings removes it from the account. Within a sweep, it is also gone from every Mac.

### The sweep

While the relay is connected, axod sweeps `~/.axo/assets` once at connect and every six hours after that.

1. Every `.download-*` temporary more than an hour old is removed. A live download is never that old, because a fetch's deadline is five minutes.
2. For every folder named by an asset's hash, `HEAD` the asset with the host credential.
   - **`404`:** the account no longer has it, so the folder is removed.
   - **Anything else, or no answer:** the folder is kept. The sweep never deletes on doubt.
3. A folder that is not a hash, a link, or a file at the top level is left alone.

Every fetch and every upload copy holds the cache's read lock while it works in the folder. A folder picked by a `404` is asked again while the sweep holds the write lock, and it is removed only if the answer is still `404`. So a copy is never removed under a fetch that is using it, and an asset uploaded again between the two answers keeps its copy.

A Mac linked to a different account sees its old account's assets as `404`, so they are removed. That is what the person asked for when they moved the Mac.

## Validation

- `link.rs` tests:
  - unlink and link both record the retired credential in the same write;
  - retiring revokes the credential before deleting its secret;
  - a `401` counts as done;
  - a relay that does not answer keeps the record;
  - a Keychain that refuses the delete keeps the record and fails loudly.
- An axod conformance test runs against a fake relay. Unlinking a linked Mac sends the revocation with the old credential, then removes it from the Keychain.
- A Worker test checks the route. It answers `204` and revokes for the current credential, and `401` for a replaced credential, a wrong one, or a request with an `Origin`.
- `assets.rs` tests:
  - the sweep removes only folders the account answers `404` for;
  - it keeps folders on errors;
  - it removes stale temporaries and leaves fresh ones;
  - a copy whose asset is uploaded again during the sweep is kept.

## Alternatives

- **A byte-budget LRU with re-fetch on open.** Pi reads files with its own tools, so axod cannot intercept an open. Re-fetching would need a new agent tool and new text in every attachment line. That cost is not worth it while the account's quota already bounds the cache.
- **Pushing deletions over the relay.** Deletions would arrive at once, but the Worker would need a new host notice and every Mac would need to handle it. The cloud package is being changed elsewhere, and a six-hour delay costs nothing here.
- **Revoking atomically in the account manager.** That would remove the reliance on axod's lock, but it means a new Durable Object method in a file another change is editing. The lock already covers every redemption this host makes.
