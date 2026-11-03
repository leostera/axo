# Changelog

What changed in each published version of Axo. Every publish raises the minor version; the build numbers are the Mac app's and axod's.

## 0.3 (Mac app build 270, axod 29)

### New

- **Pin Sessions to the top of the sidebar.** Hover a Session and click its pin, or use Pin Session in its menu; click again to unpin. Pinned Sessions stay at the top, keep their recent-activity order among themselves and always show their pin, and Previous/Next Session (⇧⌘[ and ⇧⌘]) follow them. Pins belong to this Mac only.
- **Archived Sessions live in the cloud** (RFD0027). Once the cloud holds an archived Session's whole transcript, this Mac deletes its copy, freeing the space old conversations take in `~/.axo/sessions/`. Reopening the Session (⇧⌘T, or Pi's `/resume`) fetches the transcript back and checks it before Pi starts. Nothing Pi wrote is lost.
- **Other Macs' archived Sessions aren't kept here.** Opening one fetches its transcript, and this Mac's copy goes when its pane closes.

### Changed

- Reopening an archived Session whose transcript is in the cloud needs the cloud: if it can't be reached within 60 seconds the reopen fails and nothing changes. Try again once you're online.
