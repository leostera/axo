# Update the existing phone first

The installed phone is still `dev.leostera.axo.phone`. The person requested shipping the
existing improvements before making AxoMobile or migrating to the new Apple identity.

This **manual-only** Bazel package signs the current shared implementation with the installed
phone/watch/widget identifiers and existing development profiles. It preserves the app container,
default UserDefaults (including the Secure Enclave representation), exact phone Keychain group
and token-service name. There is no new signer, credential export, importer or second codebase.
The canonical targets and generated Xcode project remain under `dev.leostera.axo`.

```sh
bazel test //apple/ExistingPhoneUpdate:archive_test --jobs=4 --test_output=errors
bazel build //apple/ExistingPhoneUpdate:ipa --jobs=4
```

Neither command installs, launches or restarts any app. Installation is a separately approved
device operation after checking the installed identity, recording state and signed archive.
**Never upload this development IPA to a public CDN:** embedded profiles contain device metadata.

Remove this package and `PhoneStorageIdentity.existingPhone` only after the explicit canonical
migration is implemented, validated on the owned device and approved for retirement. Updating
the old app is not evidence that cross-identifier migration or APNs works. AxoMobile/iPad work
starts after this release is delivered.
