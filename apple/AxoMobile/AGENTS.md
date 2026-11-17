# Mobile delivery

For mobile changes, deployment to the person's owned devices is part of completion, not an optional follow-up. The person has given standing approval for routine, in-place development updates: test, commit and push integrated clean main, then install on the owned iPhone and any provisioned owned iPad. Do not repeatedly ask for approval to perform these normal updates.

Preserve the existing app identity, container, sign-in, credential namespace and trusted-device key. Use the repository's Bazel targets, including `//apple/ExistingPhoneUpdate:ipa` while that is the approved identity-preserving installation path. Never uninstall, reset data, migrate identities, create credentials or change developer-account/provisioning state under this standing approval.

Verify the actual installed version and launch where the OS allows it. Report unreachable devices, locked-device launch failures and missing provisioning explicitly; do not call an undeployed change done. Do not bypass locks or other device safeguards.

This standing mobile deployment approval does not authorize restarting active Mac apps, daemons or Sessions. Other platform rollout constraints still apply.
