# RFD0071 - Axo: sign-in leases for open sockets

- Feature Name: `socket-sign-in-leases`
- Status: Implemented
- Author: leostera
- Start Date: 2026-11-18
- Document Type: Proposal
- Amends: [RFD0013](RFD0013-cloudflare-oauth-and-host-pairing.md) (lifecycle: a revoked session or host credential), [RFD0032](RFD0032-push-delivery.md) (protocol 3's client sockets)
- Related: [RFD0031](RFD0031-durable-objects-wake-on-demand.md) (no alarm renews, polls or re-checks)

## Summary

Every client socket the cloud holds carries the sign-in it was opened with and a lease of five
minutes. Before the object reads a frame from a socket, or writes one to it, past the lease's end,
it asks the account whether that sign-in still stands, and renews the lease or closes the socket.
After signing out, a session evicted by a newer one, or a revoked Mac, no socket of theirs reads or
receives anything more than five minutes on, not until the sign-in's expiry, 30 to 90 days later.

## Motivation

RFD0013 says a revoked session stops browser access and a revoked host credential closes the
host's socket. The code checked a sign-in once, when a socket was upgraded, and gave the socket
the sign-in's expiry (`X-Axo-Expiry`). After that, nothing asked again:

- `POST /api/auth/logout` and the eviction of a 21st session delete the session's row, but its
  account socket (ClientDO) and its sockets on each Mac (HostDO, protocol 3) stay open and keep
  working until the session's own expiry. A stolen token, signed out, keeps every Mac for 30 days
  on the web and 90 on the phone.
- Revoking a Mac closes its daemon socket, but not the sockets it opened as a client: its peers
  socket on its ClientDO and its sockets on the account's other Macs, which can still send
  `axo.client.command`, for up to an hour (`PEERS_SIGN_IN_MS`). People's sockets on the revoked
  Mac's HostDO stay open too.

## Design

`src/auth/sign-in-lease.ts` holds the contract.

- **A sign-in** is `{ kind: "session", digest }`, the HMAC the account keeps of a session token,
  or `{ kind: "host", hostId, credentialId }`, a paired Mac's current credential. The Worker passes
  it to the object that will hold the socket in `X-Axo-Sign-In`, beside `X-Axo-Expiry`, on every
  client route: the account socket, the peers socket, and a person's or a Mac's socket on a host.
- **A lease** is `leaseUntil = min(expiresAt, now + SIGN_IN_LEASE_MS)`, five minutes, kept in the
  socket's attachment, so it survives hibernation.
- **Confirming** is one RPC, `AxoAccountManager.confirmSignIn(signIn, now, onHost?)`: the session
  is still in `sessions` and unexpired, or the host is linked (`revoked_at IS NULL`) with that
  credential ID. A socket on a host's HostDO also names that host, which must still be linked.
- **When** a lease has ended, the object confirms it before it reads the socket's next frame and
  before it writes to the socket: ClientDO in `notify` and `hostsChanged`, HostDO's client sockets
  in `deliver` and `committed`. A cut tells only sockets within their lease; one past it learns of
  the cut with a read, as one further behind does. No alarm is set for a lease: RFD0031's rule
  stands, an object wakes only for work. A socket of an ended sign-in that nothing reaches stays
  open, inert, until its next frame either way closes it.
- **The answer** renews the lease, or closes the socket with 4001. An account that cannot be asked
  closes it too: fail closed, as RFD0013 asks. Clients reconnect as they do after any close, and a
  reconnect without a good sign-in is refused at the Worker.
- HTTPS clients (the watch) need no lease: each request is signed in on its own, and its mailbox's
  45-second lease is renewed only by signed-in requests.

A socket accepted before this change has no sign-in in its attachment; it is treated as lapsed and
closes at its next frame or alarm. Deploying a new version resets every socket anyway.

### Invariants

1. No frame is read from or written to a client socket more than `SIGN_IN_LEASE_MS` after its
   session is signed out, evicted or expired, or its Mac revoked.
2. A socket on a host's HostDO is served only while that host is linked to the account, to the same
   bound.
3. A sign-in that stands is never closed by its lease: renewal does not change what the socket can
   do, see or has open.

### Cost

At most one account RPC per client socket per five minutes, and only while frames go in or out:
the object is awake for them anyway. An idle socket costs nothing.

## Alternatives

- **Push the end of a sign-in.** On sign-out or revocation the account would tell every ClientDO
  and HostDO that may hold a socket of it. It is immediate, but the account does not know every
  object a sign-in reached (a socket that has not said hello yet follows nothing), and a lost call
  leaves the socket open for days. A lease bounds every case, including the ones a fan-out misses;
  one could be added later to make the common sign-out faster.
- **An alarm at each lease's end.** It would close a socket of an ended sign-in even if nothing
  reaches it, at one wake every five minutes for every connected client's objects. RFD0031 removed
  such a wake (every 30 s) for 63% of all Durable Object time, and a socket nothing reaches leaks
  nothing.
- **Short socket expiries.** Giving each socket a five-minute `X-Axo-Expiry` would make every
  client reconnect every five minutes, with a full hello and resubscription each time.

## Testing

`tests/socket-sign-in.test.ts` (`//packages/axo-api-worker:sign_in_test`) runs the Worker with a
400 ms lease (`SIGN_IN_LEASE_MS`, which can only shorten it). After a sign-out, the session's
account socket closes at its next frame in and its socket on a Mac at the Mac's next notice out,
while another session's sockets are renewed and go on. After a revocation, the Mac's peers socket,
its socket on another Mac and a person's socket on it close the same way.
