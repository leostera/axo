# RFD0027 - Axo: Archived Sessions Live in the Cloud

- Feature Name: `axo-archived-sessions-in-the-cloud`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-03
- Updated: 2026-11-03
- Document Type: Proposal
- Amends: [RFD0018](RFD0018-session-sync-and-client-delivery.md), [RFD0022](RFD0022-sessions-across-macs.md)

## Summary

An archived Session may be deleted from a Mac once the cloud is known and confirmed to hold it. Opening it again fetches it back.

- **Other Macs' archived Sessions** are not copied (RFD0022's mirror). A pane on one fetches it for as long as the pane is open.
- **This Mac's archived Sessions** are deleted once the cloud has acknowledged every record. Reopening one restores its transcript from the cloud, byte for byte, before Pi starts.

## Motivation

Every Mac keeps every transcript. That is 812 MB of this Mac's own Sessions on Leo's laptop, plus a copy of every other Mac's (RFD0022). Almost all of them are archived and never read again here. The phone and the web app already read them from the cloud. RFD0022 asked whether old archived Sessions should be skipped and fetched on demand. Leo's answer: archived Sessions may be deleted from local storage if they are known and confirmed to be in the cloud.

## Guide-level explanation

Archiving a Session is unchanged. A little later, once its last line is safely in the cloud, its transcript file disappears from `~/.axo/sessions/`. Everything else about the Session stays in `axo.db`: its name, its Workspace, its panes, and where the transcript lived. Reopening it (⇧⌘T, or resuming its Pi) downloads the transcript to the same path first, and then reopens as before. With no connection, reopening says that the transcript is in the cloud and could not be fetched.

Other Macs' archived chats work the same way. They are not kept here, and opening one shows it as soon as it arrives.

## Reference-level explanation

### Other Macs' Sessions

This part is built (a7ff98b).

- **The follower** (`peers.rs`) does not open an archived Session, and deletes its copy.
- **Panes:** `axo.peer.session.open` marks the Session wanted (`PeerLive::want`). The follower then opens it from nothing, and the pane draws it as it arrives. Closing the pane, or its Pi exiting, unmarks it, and the copy is deleted again.
- **Listing:** the sidebar still lists only open Sessions. Opening and watching reach archived ones too, so a pane survives its Session being archived.

### This Mac's Sessions: eviction

The uploader (`sync.rs`) evicts an archived Session's transcript when all of these hold:

1. **Archived.** The Session is archived in `axo.db`.
2. **Confirmed.** The cloud holds every record of the file. The last handshake or acknowledgement put the cloud's count at the file's count, with the same chain, and that cursor is stored in `axo.db`.
3. **Settled.** The file has not changed since that confirmation: the uploader's last check found nothing new, and the file is not invalid past some line.

Eviction happens in this order:

1. **Record it.** `axo.db` records that the transcript is in the cloud, with the count and chain the cloud confirmed (`transcript_in_cloud`).
2. **Delete the file**, and its Pi lock file.
3. **Forget it in memory.** The uploader drops its in-memory transcript for the Session.

A crash between steps 1 and 2 leaves a file the next pass deletes. Step 2 never comes before step 1.

An evicted Session's manifest row carries no `upload` (`upload: null`). RFD0018's handshake already treats that as "a Mac with no transcript leaves the cloud's copy as it is". So nothing is truncated, and nothing is appended. Metadata still goes up.

### This Mac's Sessions: restore

Reopening an archived Session (`reopen_archived`) whose transcript is in the cloud and whose file is missing first restores it:

1. **Fetch.** axod asks the peers socket to fetch the Session's records from the cloud (`PeerLive::restore`). The follower opens this Mac's own Session from nothing, through the same `axo.client.session.open` and acknowledgements as a copy, and writes it at the Session's path.
2. **Verify.** The restored file must have the count and chain `axo.db` recorded. Otherwise it is deleted and the reopen fails.
3. **Clear the record.** `transcript_in_cloud` is cleared, and the reopen goes on as before. The uploader finds the file, and its handshake finds the cloud in sync.

If the fetch fails or times out (60 seconds), the reopen fails with "This Session's transcript is in the cloud and could not be fetched", and nothing changes.

### Invariants

- **A Mac never deletes a transcript the cloud has not confirmed whole.** Eviction requires the stored cursor to equal the file's count, with the same chain, and records that before it deletes.
- **A missing transcript never cuts the cloud.** An evicted Session reports no upload. Pi never starts on a missing history (`restart_unavailable_pi` refuses, as it already does), so a fresh file can never replace the cloud's.
- **A restored transcript is the one that was evicted.** It is verified against the count and chain recorded at eviction before Pi sees it.

## Testing

- **Feynman:** `specs/archived-in-the-cloud.ts` models the Mac's file, its `axo.db` record, the uploader, the cloud, Pi and crashes at every step. It checks that the cloud never loses a confirmed record, that Pi never runs on a missing or partial transcript, and that a restored file equals the evicted one.
- **axod:**
  - eviction waits for the cloud's confirmation, and survives a crash between recording and deleting;
  - an evicted Session's manifest has no upload;
  - reopening restores and verifies, and refuses a mismatched or missing download.
- **Relay end-to-end:** two axods and the Worker (`axod-peers.test.ts`): a copy of an archived Session goes, comes back with a pane, and goes when the pane closes (built). Evicting and restoring this Mac's own Session follows.

## Drawbacks

- **Reopening an old Session needs the network.**
- **Tools that read transcripts on disk** (`session_catalog`'s `piSessionFile`) find no file for an evicted Session.

## Unresolved questions

- How long after archiving should eviction wait? This proposal evicts as soon as the Session is confirmed, since restoring is cheap.
