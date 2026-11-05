# AXP extension: `assets`

```text
Identifier: assets
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      hub, host, client
```

Files an account keeps at its hub, named by a hash of their bytes: a photo attached from a phone, a PDF dropped in a browser, a screenshot a host took. Other extensions refer to them by name, in commands and in logs, instead of carrying their bytes.

## 1. Model

- An **asset** is a sequence of bytes, named `<algorithm>:<digest>`: a hash algorithm from §1.1, a colon, and the lowercase hex digest of the bytes under that algorithm, for example `sha256:9f2c…`. The same bytes under the same algorithm always have the same name. (This is a plain hash of the bytes, not an ATXF record hash, which is domain-separated; the two only share their notation.)
- The same bytes named under two algorithms are two assets. A hub MAY store them once.
- Assets belong to an **account** at a hub. Each account has its own namespace: the same bytes uploaded to two accounts are two assets, and nothing a device of one account can observe reveals what another account holds.
- An asset has **metadata**, set when it is first uploaded:
  - `name`: a file name to show and save as, 1 to 255 bytes of UTF-8, with no `/`, `\` or control characters, and not `.` or `..`;
  - `mediaType`: a media type such as `image/png`;
  - `size`: its length in bytes;
  - `createdAt`: when it was first uploaded;
  - `version`: a positive integer the hub raises on every successful upload of it, including uploads of bytes it already holds (§3), so that a delete can name the version it saw (§4).
- Assets are **immutable**. Bytes never change under a name; an asset only comes into existence and, later, goes away.

Hosts and clients MAY keep copies of assets they have fetched, by name, for as long as they like.

### 1.1 Algorithms

| Algorithm | Digest | Hex digits | `ni` name (§6) |
| --- | --- | --- | --- |
| `sha256` | SHA-256 | 64 | `sha-256` |
| `sha384` | SHA-384 | 96 | `sha-384` |
| `sha512` | SHA-512 | 128 | `sha-512` |
| `sha3-256` | SHA3-256 | 64 | `sha3-256` |
| `sha3-512` | SHA3-512 | 128 | `sha3-512` |

- Every hub, host and client MUST support `sha256`. Devices SHOULD name assets with `sha256` unless they need a stronger guarantee.
- A hub answers the algorithms it accepts in `assets.limits` (§2.1) and refuses others with `-32349` (`unsupportedAlgorithm`).
- A reader that cannot compute an asset's algorithm MUST NOT use its bytes: it cannot check them.
- Truncated digests are not allowed. New algorithms are added by a new version of this extension.

## 2. Methods

All methods are hub methods, called by any authenticated device of the account (host or client). None is routed (SPEC §10.1).

| Method | Params | Result |
| --- | --- | --- |
| `assets.limits` | | `{ "algorithms", "assetBytes", "accountBytes", "accountAssets", "chunkBytes", "attachments" }` |
| `assets.has` | `assets` | `{ "present" }` |
| `assets.put` | `asset`, `name`, `mediaType`, `size` | `{ "state", "upload"?, "url"? }` |
| `assets.chunk` | `upload`, `offset`, `data` | `{ "received" }` |
| `assets.commit` | `upload` | `{ "asset": Asset }` |
| `assets.abort` | `upload` | `{}` |
| `assets.get` | `asset`, `offset`?, `length`? | `{ "asset": Asset, "offset", "data", "done" }` |
| `assets.url` | `asset` | `{ "url", "expiresAt" }` |
| `assets.list` | `before`?, `limit`? | `{ "assets": [Asset], "next", "usage": { "bytes", "assets" } }` |
| `assets.delete` | `asset`, `version` | `{}` |

`Asset` is `{ "asset", "name", "mediaType", "size", "createdAt", "version" }`.

### 2.1 Limits

`assets.limits` answers the algorithms the hub accepts in asset names (always including `sha256`), and the hub's limits for the caller's account: the largest asset, the bytes and the number of assets the account may hold, the largest chunk `assets.chunk` and `assets.get` carry, and the most attachments one command may name (§5). Defaults are 100 MiB, 10 GiB, 10,000, 256 KiB and 8.

### 2.2 Checking

`assets.has` takes up to 64 names and answers the ones the account holds and are ready, so a device can skip uploading what is already there.

## 3. Uploading

An upload is reserved, filled, then committed:

1. **Reserve.** `assets.put` names the asset and its metadata. The hub checks the limits and the name, and answers one of:
   - `{ "state": "exists" }`: the account already holds the asset. Nothing more is sent. The asset's `version` is raised, as for any successful upload.
   - `{ "state": "reserved", "upload": <id> }`: the hub has reserved `size` bytes against the account's quota. A reservation counts against the quota from the moment it is made, so uploads in parallel cannot overshoot it.
   - an error: `-32340` (`quota`), `-32341` (`busy`, the asset is being deleted, §4), `-32349` (`unsupportedAlgorithm`), or `-32602` for invalid metadata.
2. **Send the bytes**, in one of two ways:
   - **In band:** `assets.chunk` calls in order, each with the `offset` of its first byte and up to `chunkBytes` of `data`. The hub answers the number of bytes received so far. A chunk whose `offset` is not the number already received is refused with `-32342` (`badOffset`), whose `data.received` says where to continue, so a device that lost a response can resume. Chunks are in the `durable` priority class (SPEC §4.1).
   - **Out of band:** if the reservation carries a `url`, the device MAY instead send the bytes as the body of an HTTPS `PUT` to it, with `Content-Length: <size>`. The URL is a capability for this one upload, expires with the reservation, and needs no other credential.
3. **Commit.** `assets.commit` asks the hub to check that it received exactly `size` bytes whose digest, under the name's algorithm, is the name's digest. It answers the `Asset`, now ready, or `-32343` (`mismatch`) and discards the upload. A hub MUST NOT make an asset ready whose bytes do not hash to its name. A commit is answered only once the asset is durable: an upload whose commit was answered is in the account.

`assets.abort` releases a reservation. A hub MUST release a reservation that is not committed within 10 minutes; a later chunk or commit for it fails with `-32344` (`unknownUpload`).

## 4. Reading and deleting

- **In band:** `assets.get` answers up to `chunkBytes` bytes of the asset, from `offset` (default 0) for `length` bytes (default as many as fit), with `done: true` on the last range. A device reads a large asset with several calls.
- **Out of band:** `assets.url` answers an HTTPS URL that serves the asset's bytes with a plain `GET` until `expiresAt`, at most 10 minutes later. A hub that does not offer URLs answers `-32345` (`noUrl`) and the device reads in band.
- A reader MUST check that the bytes it received hash to the asset's name before using them, however it fetched them.
- `assets.get` and `assets.url` for an asset the account does not hold, or that is not ready, answer `-32346` (`unknownAsset`).

`assets.list` answers the account's ready assets, newest first, in pages of at most `limit` (default and maximum 100), with the account's usage. `next` is passed as `before` for the next page, and is `null` on the last.

`assets.delete` deletes an asset only if its `version` is still the one given. If the asset has been uploaded again since the caller saw it, the hub answers `-32347` (`staleVersion`) and keeps it: an older delete must not remove a file someone has just attached again. While a delete is in progress, `assets.put` for the same name answers `busy`. A hub MAY keep serving a deleted asset's bytes to its own account for a short, bounded time while caches are purged, and MUST say how long.

## 5. Attachments

Other extensions refer to assets with an **attachment**: `{ "asset", "name", "mediaType", "size" }`. An extension that takes attachments in a command (such as `agent.prompt`) follows these rules:

- A client sends the command only after every asset it attaches has been committed.
- A command names at most `attachments` assets (§2.1).
- The host fetches every attached asset it does not already hold, from the hub, and checks each one's hash, **before** acting on the command. If any attachment is missing, larger than its `size`, or does not match its name, the host refuses the whole command with `-32348` (`attachmentUnavailable`, retry `safe`) and does nothing with it. A command is never carried out with some of its attachments.
- A host fetches attachments without holding up its other traffic: a host that is fetching answers other calls meanwhile.

## 6. Assets in logs

An ATXF content block refers to an asset by URI rather than carrying its bytes. The URI is the [RFC 6920](https://www.rfc-editor.org/rfc/rfc6920) named-information URI of the asset's digest: `ni:///`, the algorithm's `ni` name (§1.1), `;`, and the base64url encoding, without padding, of the digest's bytes. For example the asset `sha256:9f2c…` is `ni:///sha-256;nyw…`, and `sha512:…` is `ni:///sha-512;…`. An asset name and its URI convert into each other without loss.

- An image is `{ "type": "image", "mediaType", "uri": "ni:///sha-256;…" }`.
- Any other file is `{ "type": "resource", "uri": "ni:///sha-256;…", "name", "mediaType" }`.

A host SHOULD refer to an asset the hub holds instead of inlining its bytes in a log. The record's ATXF hash covers the URI, and the URI is the hash of the bytes, so the log's integrity still covers the file. A reader resolves the URI with `assets.get` or `assets.url` from the hub of the account the log belongs to.

## 7. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32340 | `quota` | `never` | The account's bytes or assets would exceed its limits. |
| -32341 | `busy` | `safe` | The asset is being deleted; try again after `retryAfterMs`. |
| -32342 | `badOffset` | `safe` | The chunk does not continue the upload; `data.received` says where to. |
| -32343 | `mismatch` | `never` | The bytes received do not hash to the asset's name, or are not `size` long. |
| -32344 | `unknownUpload` | `never` | No such reservation, or it expired. |
| -32345 | `noUrl` | `never` | The hub does not offer URLs; read or write in band. |
| -32346 | `unknownAsset` | `never` | The account does not hold this asset. |
| -32347 | `staleVersion` | `never` | The asset was uploaded again since the version given. |
| -32348 | `attachmentUnavailable` | `safe` | An attachment could not be fetched or did not match; the command was not carried out. |
| -32349 | `unsupportedAlgorithm` | `never` | The hub does not accept the asset name's hash algorithm. |

## 8. Security and privacy

- **Names are checked everywhere.** A hub verifies bytes against their name before making an asset ready, and every reader verifies them again. Neither a hub nor a URL's server can substitute bytes.
- **A name is as strong as its algorithm.** A log or command that names an asset by a stronger hash binds to its bytes with that strength, whichever algorithm other assets use.
- **No cross-account inference.** Because namespaces are per account, `exists`, `assets.has` and timing reveal only what the caller's own account holds. A hub MUST NOT deduplicate storage across accounts in any way a device can observe.
- **Nothing served runs.** A hub that serves assets over HTTP MUST NOT serve active content (HTML, SVG, scripts) inline from an origin that holds credentials. It SHOULD serve only common image types inline, everything else as an attachment, with `X-Content-Type-Options: nosniff` and a sandboxing `Content-Security-Policy`.
- **URLs are capabilities.** Anyone holding an `assets.url` or upload URL can use it until it expires. Hubs keep their lifetime short and devices MUST NOT log them.
- **The hub can read assets,** as it can read logs. Values a person enters for the agent not to see must never become assets.
