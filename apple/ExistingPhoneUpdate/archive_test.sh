#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 - "$@" <<'PY'
import datetime, json, pathlib, plistlib, subprocess, sys, tempfile, zipfile

config = json.loads(pathlib.Path(sys.argv[1]).read_text())
phone = "dev.leostera.axo.phone"
watch = phone + ".watchkitapp"
expected = {phone, watch, watch + ".complications"}
found = set()
with tempfile.TemporaryDirectory(prefix="axo-existing-phone-") as directory:
    with zipfile.ZipFile(sys.argv[2]) as archive:
        archive.extractall(directory)
    # security cms imports certificates into the default Keychain. Never use the person's
    # Keychain as a test fixture: verify CMS against read-only system Apple roots instead.
    roots = subprocess.run(
        ["/usr/bin/security", "find-certificate", "-a", "-p", "-c", "Apple Root CA",
         "/System/Library/Keychains/SystemRootCertificates.keychain"],
        check=True, capture_output=True).stdout
    assert b"BEGIN CERTIFICATE" in roots
    root_file = pathlib.Path(directory) / "apple-roots.pem"
    root_file.write_bytes(roots)
    for info_path in pathlib.Path(directory).rglob("Info.plist"):
        info = plistlib.loads(info_path.read_bytes())
        identifier = info.get("CFBundleIdentifier", "")
        if not identifier.startswith("dev.leostera.axo"):
            continue
        assert identifier in expected, "Unexpected Axo identity in installed-phone update"
        found.add(identifier)
        assert info["CFBundleShortVersionString"] == config["version"]
        assert info["CFBundleVersion"] == str(config["builds"]["phone"])
        if identifier == phone:
            assert set(info["UIDeviceFamily"]) == {1, 2}, "The owned-device test build must be universal"
            assert len(set(info["UISupportedInterfaceOrientations~ipad"])) == 4
        if identifier == watch:
            assert info["WKCompanionAppBundleIdentifier"] == phone
        bundle = info_path.parent
        requirement = 'anchor apple generic and certificate leaf[subject.OU] = "' + config["apple"]["team"] + '"'
        verified = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle)],
            capture_output=True)
        assert verified.returncode == 0, "Apple/team signature verification failed: " + verified.stderr.decode()
        decoded = subprocess.run(
            ["/usr/bin/openssl", "smime", "-verify", "-inform", "DER", "-purpose", "any",
             "-CAfile", str(root_file), "-in", str(bundle / "embedded.mobileprovision")],
            capture_output=True)
        assert decoded.returncode == 0, "Profile decoding failed: " + decoded.stderr.decode()
        profile = plistlib.loads(decoded.stdout)
        assert profile["TeamIdentifier"] == [config["apple"]["team"]]
        assert profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        prefixes = profile["ApplicationIdentifierPrefix"]
        assert len(prefixes) == 1
        application_id = prefixes[0] + "." + identifier
        assert profile["Entitlements"]["application-identifier"] == application_id
        signed = subprocess.run(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)],
            check=True, capture_output=True).stdout
        entitlements = plistlib.loads(signed)
        assert entitlements["application-identifier"] == application_id
        if "com.apple.developer.team-identifier" in entitlements:
            assert entitlements["com.apple.developer.team-identifier"] == config["apple"]["team"]
        if identifier == phone:
            assert entitlements["keychain-access-groups"] == [application_id]
assert found == expected, "Incomplete installed-phone companion graph"
print("Existing phone/watch/widget identities, signatures, profiles, versions and phone Keychain group verified.")
PY
