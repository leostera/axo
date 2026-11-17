#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 - "$@" <<'PY'
import json, plistlib, sys
with open(sys.argv[1]) as f:
    apple = json.load(f)["apple"]
ids = apple["bundle_ids"]
assert ids["mac"] == ids["phone"] == "dev.leostera.axo"
assert ids["watch"] == ids["phone"] + ".watch"
assert apple["phone_profile"] == "iOS Team Provisioning Profile: " + ids["phone"]
assert apple["watch_profile"] == "iOS Team Provisioning Profile: " + ids["watch"]
assert apple["watch_complication_profile"] == "iOS Team Provisioning Profile: " + ids["watch"] + ".complications"
for path, group in [(sys.argv[2], ids["phone"]), (sys.argv[3], "$(AppIdentifierPrefix)" + ids["phone"])]:
    with open(path, "rb") as f:
        entitlement = plistlib.load(f)
    assert entitlement["keychain-access-groups"] == [group]
with open(sys.argv[4], "rb") as f:
    companion = plistlib.load(f)
assert companion["WKCompanionAppBundleIdentifier"] == ids["phone"]
print("Canonical phone/Mac identity, watch hierarchy, profiles and Keychain entitlements agree.")
PY
