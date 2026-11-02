# AXP extension: `share`

```text
Identifier: share
Version:    0.1
Status:     Draft
Requires:   core only
Roles:      hub, host
```

Publishing a read-only copy of a Session for anyone with the link. A share is an ATXF transcript the host redacted before it left the host.

## 1. Methods

| Method | Caller | Params | Result |
| --- | --- | --- | --- |
| `share.publish` | host → hub | `sessionId`, `title`, `transcript` | `{ "shareId", "url" }` |
| `share.unpublish` | host or client → hub | `shareId` | `{}` |
| `share.list` | client → hub | | `{ "shares": [{ "shareId", "url", "hostId", "sessionId", "title", "publishedAt" }] }` |

- `transcript` is `{ "header", "records" }`, a complete ATXF transcript. It is a new transcript, not the Session's log: its header has a new `id` and names the Session as its `parent`. The host chooses what to keep and redacts it; it SHOULD drop `native`, `replay`, reasoning and tool outputs unless the person publishing chose otherwise.
- The hub validates the transcript, picks `shareId` (at least 128 bits of randomness, base64url), stores it, and serves it at `url` without authentication, both as a page and as `application/jsonl` ATXF.
- `share.unpublish` deletes the copy. The hub MUST stop serving it at once and SHOULD purge caches.

## 2. Errors

| Code | Name | `retry` | Meaning |
| --- | --- | --- | --- |
| -32280 | `invalidTranscript` | `never` | The transcript is not valid ATXF. |
| -32281 | `unknownShare` | `never` | No such share in this account. |

## 3. Privacy

A share is public. The hub MUST NOT add anything to it that the host did not send, such as the account's name, unless the person publishing chose that.
