# RFD0027 - Axo: Archived Sessions Live in the Cloud

- Feature Name: `axo-archived-sessions-in-the-cloud`
- Status: Draft
- Author: leostera
- Start Date: 2026-11-03
- Updated: 2026-11-03 (as built)
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

- **The follower** (`peers.rs`) does not open an archived Session, and deletes its copy.
- **Panes:** `axo.peer.session.open` marks the Session wanted (`PeerLive::want`). The follower then opens it from nothing, and the pane draws it as it arrives. Closing the pane, or its Pi exiting, unmarks it, and the copy is deleted again.
- **Listing:** the sidebar still lists only open Sessions. Opening and watching reach archived ones too, so a pane survives its Session being archived.

### This Mac's Sessions: eviction

The uploader (`sync.rs`) evicts an archived Session's transcript when all of these hold:

1. **Archived.** The Session is archived in `axo.db`.
2. **Confirmed.** The cloud holds every record of the file. The last handshake or acknowledgement put the cloud's count at the file's count, with the same chain, and that cursor is stored in `axo.db`.
3. **Settled.** The file has not changed since that confirmation: the uploader's last check found nothing new, and the file is not invalid past some line.

The uploader asks axod to evict it (`RelayHost::evict_transcript`), passing the count, chain and file length it confirmed. Under the catalog lock, axod refuses if:

- the Session has panes, or is being reopened;
- it is no longer archived;
- the file's length changed;
- `axo.db`'s cursor is not that count and chain.

Otherwise it evicts in this order:

1. **Record it.** `axo.db` records that the transcript is in the cloud: `relay_sync.in_cloud`, beside the cursor that names the count and chain.
2. **Delete the file**, and its Pi lock file.
3. **Forget it in memory.** The uploader drops its in-memory transcript for the Session.

Step 2 never comes before step 1. A crash between them leaves a file that the record vouches for, and reopening uses it without fetching. If axod refuses, the uploader does not ask again until the Session's metadata changes.

While `in_cloud` is set, the uploader does not read the file, even if one is there.

An evicted Session's manifest row carries no `upload` (`upload: null`). RFD0018's handshake already treats that as "a Mac with no transcript leaves the cloud's copy as it is". So nothing is truncated, and nothing is appended. Metadata still goes up.

### This Mac's Sessions: restore

Reopening an archived Session (`reopen_archived`, and Pi's `/resume` of an archived history) first marks the Session as reopening, so nothing evicts it meanwhile. If its transcript is in the cloud and is not on disk, axod then restores it:

1. **Fetch.** axod asks the peers socket to fetch the Session's records from the cloud (`PeerLive::restore`). The follower opens this Mac's own Session from nothing, through the same `axo.client.session.open` and acknowledgements as a copy. It writes them to a staging folder, `~/.axo/server/restoring/`, and closes the Session on the socket once it has every record. The cloud lets a Mac's peers socket open its own Sessions: the ones it lists are still only the other Macs'.
2. **Verify, then move.** The staged file must have the count and chain `axo.db` recorded. If it does, it is renamed into place. Otherwise it is deleted, and the reopen fails.
3. **Clear the record.** Under the same catalog lock that reopens the Session, axod checks that the transcript is back and clears `in_cloud`. The reopen then goes on as before. The uploader finds the file, and finds the cloud in sync.

If the fetch fails or times out (60 seconds), the reopen fails with "This Session's transcript is in the cloud and could not be fetched", and nothing changes.

### Invariants

- **A Mac never deletes a transcript the cloud has not confirmed whole.** Eviction requires the stored cursor to equal the file's count, with the same chain, and records that before it deletes.
- **A missing transcript never cuts the cloud.** An evicted Session reports no upload. Pi never starts on a missing history (`restart_unavailable_pi` refuses, as it already does), so a fresh file can never replace the cloud's.
- **A restored transcript is the one that was evicted.** It is verified against the count and chain recorded at eviction before Pi sees it, and it only reaches the Session's path whole, by a rename.
- **A transcript missing here is recorded as in the cloud**, so reopening knows to fetch it.
- **A Session being reopened keeps its transcript.** Without this, a reopen could find the file, lose it to an eviction before taking the catalog lock, and fail for no reason. The spec found this.

## Testing

- **Feynman:** `specs/archived-in-the-cloud.ts` models the following:
  - the Mac's file, its `axo.db` record, and the uploader;
  - the cloud and Pi;
  - lost replies, and crashes at every step.

  It checks four properties: no line Pi wrote is lost, Pi runs only on the whole transcript, a missing transcript is recorded as in the cloud, and a reopen is not undone. It also checks the rules each property needs: `confirmedWhole`, `recordBeforeDelete` and `keepWhileReopening`.
- **axod:**
  - `axo-store`: only an archived Session at its acknowledged cursor is marked.
  - `cloud_transcripts`:
    - eviction is refused for a changed file, another cursor, or an open Session;
    - a reopen needs the whole transcript back;
    - a crash between recording and deleting needs no fetch;
    - a failed fetch changes nothing.
  - `sync`: a transcript has a chain only when every line is a whole record.
- **Relay end-to-end:** real axods and the Worker (`axod-peers.test.ts`):
  - A copy of another Mac's archived Session is deleted, comes back with a pane, and is deleted again when the pane closes.
  - This Mac's own Session, longer than one batch, is uploaded, then deleted once archived. Reopening restores it byte for byte, and its next line is uploaded.

## Drawbacks

- **Reopening an old Session needs the network.**
- **Tools that read transcripts on disk** (`session_catalog`'s `piSessionFile`) find no file for an evicted Session.

## Unresolved questions

- How long after archiving should eviction wait? This proposal evicts as soon as the Session is confirmed, since restoring is cheap.
