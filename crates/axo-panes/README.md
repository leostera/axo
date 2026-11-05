# axo-panes

The catalog's open panes and their lifecycle, as a table generic over the process type so every transition is tested on its own.

A pane is `Pane::Running` or `Pane::Unavailable` (a Pi pane whose process exited or could not be restored, kept so its history can be recovered). One map holds both, so a pane cannot be running and unavailable at once, and every query over a Session sees each pane once.

Recovery is a reservation: `begin_recovery` under the catalog lock, then waiting and spawning outside it, then `commit_recovery` or `release_recovery` under the lock again. Only the reservation that is still current may commit, so a close, a removal or a newer recovery always wins over a stale one.

## Build and test

```sh
bazel build //crates/axo-panes
bazel test //crates/axo-panes:axo_panes_tests
```
