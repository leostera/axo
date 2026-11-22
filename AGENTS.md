# Delivery

For each integrated product change, release without waiting for a separate “ship” request. Test the exact release commit, publish only affected deliverables through their official channels, deploy web directly at tag time if web changed, and install changed clients in place on compatible owned devices. Determine scope from shipped behavior and dependencies; do not republish or restart unchanged clients just because another platform shipped. A local build, a push or a tag is not completion.

Inventory the fleet (Macs, iPhone, iPad, Watch, Windows and Linux hosts); record installed identity/version before each update. Preserve app data, profiles, credentials and active work. Honor signing, provisioning, installer confirmations and idle gates. Retry held devices when available; never force an update, silently substitute a package, or reuse an approval outside its scope.

Verify public bytes, production web commit and assets, per-device installed build, and actual daemon readiness where applicable. Report offline, incompatible or blocked devices individually. Reconcile prior release attempts before retrying. Do not recursively release documentation-only delivery receipts.
