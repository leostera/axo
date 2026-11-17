#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 - "$@" <<'PY'
import json, plistlib, sys, zipfile
with open(sys.argv[1]) as f:
    ids = json.load(f)["apple"]["bundle_ids"]
expected = {ids["phone"], ids["watch"], ids["watch"] + ".complications"}
found = set()
assert zipfile.is_zipfile(sys.argv[2]), "Expected app archive: " + repr(sys.argv)
with zipfile.ZipFile(sys.argv[2]) as archive:
    for name in archive.namelist():
        if not name.endswith("/Info.plist"):
            continue
        info = plistlib.loads(archive.read(name))
        identifier = info.get("CFBundleIdentifier", "")
        if not identifier.startswith("dev.leostera.axo"):
            continue
        assert identifier in expected, (name, identifier)
        found.add(identifier)
        if identifier == ids["watch"]:
            assert info["WKCompanionAppBundleIdentifier"] == ids["phone"]
assert found == expected, (found, expected)
print("Built phone, embedded Watch and complication use the canonical identity graph.")
PY
