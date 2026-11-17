"""Read-only Apple signing gates. Never signs, provisions, notarizes, installs or uploads."""
import argparse
import datetime as dt
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile


class GateError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def mobile_policy(info, entitlements, profile, *, bundle_id, team, channel, apns=False, migration=False, now=None):
    """Actual profile prefix matters: it is not necessarily the Team ID."""
    require(info.get("CFBundleIdentifier") == bundle_id, "Unexpected bundle identity")
    platforms = profile.get("Platform")
    allowed_platforms = {"iOS", "watchOS"} if info.get("CFBundleSupportedPlatforms") == ["WatchOS"] else {"iOS"}
    require(isinstance(platforms, list) and all(isinstance(value, str) for value in platforms) and
            any(value in allowed_platforms for value in platforms), "Provisioning platform mismatch")
    require(profile.get("TeamIdentifier") == [team], "Unexpected provisioning team")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    require(isinstance(prefixes, list) and len(prefixes) == 1 and isinstance(prefixes[0], str) and
            re.fullmatch(r"[A-Z0-9]{10}", prefixes[0]), "Missing or ambiguous App Identifier Prefix")
    prefix = prefixes[0] + "."
    application_id = prefix + bundle_id
    granted = profile.get("Entitlements", {})
    require(isinstance(granted, dict), "Malformed provisioning entitlements")
    for values in (granted, entitlements):
        require(values.get("application-identifier") == application_id, "Explicit application identifier mismatch")
    require(granted.get("com.apple.developer.team-identifier") == team, "Provisioning entitlement team mismatch")
    # Some development signing graphs omit this redundant entitlement. The signature's leaf
    # Team ID and the signed profile's team are mandatory evidence; a present value must agree.
    if "com.apple.developer.team-identifier" in entitlements:
        require(entitlements["com.apple.developer.team-identifier"] == team, "Entitlement team mismatch")
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, dt.datetime), "Missing provisioning expiry")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=dt.timezone.utc)
    require(expires > (now or dt.datetime.now(dt.timezone.utc)), "Provisioning profile has expired")
    development = channel == "development"
    require(granted.get("get-task-allow", False) is development, "Wrong provisioning distribution class")
    require(entitlements.get("get-task-allow", False) is development, "Wrong debugging entitlement")
    require(profile.get("ProvisionsAllDevices", False) is False, "Enterprise profiles are not an Axo distribution channel")
    devices = profile.get("ProvisionedDevices")
    if channel in ("development", "ad-hoc"):
        require(isinstance(devices, list) and len(devices) > 0 and all(isinstance(device, str) for device in devices),
                "Direct-device provisioning requires an explicit device list")
    else:
        require(channel == "app-store-connect" and devices is None, "App Store profiles must not be device-limited")
    expected_groups = [application_id]
    if migration:
        require(channel == "development", "Migration is a separately approved development operation")
        expected_groups.append(prefix + "dev.leostera.axo.migration")
    groups = entitlements.get("keychain-access-groups")
    # These already-installed development companions shipped with the profile's wildcard.
    # Preserve that namespace until an approved Watch migration; never waive canonical or
    # production policy, nor let the phone token store default to a migration/shared group.
    existing_companions = {"dev.leostera.axo.phone.watchkitapp", "dev.leostera.axo.phone.watchkitapp.complications"}
    retained_companion_group = development and not migration and bundle_id in existing_companions and groups == [prefix + "*"]
    require(groups == expected_groups or retained_companion_group, "Unexpected Keychain access groups")
    allowed = granted.get("keychain-access-groups", [])
    require(isinstance(allowed, list) and all(group in allowed or prefix + "*" in allowed for group in groups),
            "Profile does not authorize the required Keychain groups")
    if apns:
        expected_environment = "development" if development else "production"
        require(granted.get("aps-environment") == expected_environment and
                entitlements.get("aps-environment") == expected_environment, "APNs environment mismatch or missing entitlement")
    elif "aps-environment" in entitlements:
        require(entitlements["aps-environment"] == granted.get("aps-environment") == ("development" if development else "production"),
                "APNs entitlement does not match this distribution channel")


def developer_id_policy(info, entitlements, details, *, bundle_id):
    require(info.get("CFBundleIdentifier") == bundle_id, "Unexpected Mac bundle identity")
    developer_id_code_policy(entitlements, details)


def developer_id_code_policy(entitlements, details):
    flags = re.search(r"^CodeDirectory.*\bflags=0x([0-9a-fA-F]+)", details, re.MULTILINE)
    require(flags and int(flags[1], 16) & 0x10000, "Hardened runtime is required")
    timestamp = re.search(r"^Timestamp=(.+)$", details, re.MULTILINE)
    require(timestamp and timestamp[1].strip().lower() not in ("none", "not set"), "Secure signing timestamp is required")
    for name in ("com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.cs.allow-jit",
                 "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory"):
        require(entitlements.get(name, False) is False, "Unexpected debugging or executable-memory entitlement")


def run(*args):
    result = subprocess.run(args, capture_output=True, env={**os.environ, "LC_ALL": "C"})
    # Command diagnostics may contain private profile/device metadata. Only report the failed gate.
    require(result.returncode == 0, "Signing evidence could not be verified (" + Path(args[0]).name + ")")
    return result.stdout, result.stderr


def plist(path):
    try:
        value = plistlib.loads(path.read_bytes())
        require(isinstance(value, dict), "Malformed property list")
        return value
    except (ValueError, OSError, plistlib.InvalidFileException):
        raise GateError("Bundle property list could not be read") from None


def evidence(app, team, identifier=None, developer_id=False):
    requirement = '=anchor apple generic and certificate leaf[subject.OU] = "' + team + '"'
    if identifier:
        requirement += ' and identifier = "' + identifier + '"'
    if developer_id:
        requirement += ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, str(app))
    raw, _ = run("/usr/bin/codesign", "--display", "--entitlements", ":-", str(app))
    try:
        entitlements = plistlib.loads(raw) if raw.strip() else {}
    except (ValueError, plistlib.InvalidFileException):
        raise GateError("Signed entitlements could not be read") from None
    require(isinstance(entitlements, dict), "Malformed signed entitlements")
    _, details = run("/usr/bin/codesign", "--display", "--verbose=4", str(app))
    return entitlements, details.decode("utf-8", errors="replace")


def is_provisioning_signer(subject):
    # A developer certificate can also form a valid CMS chain to Apple roots. It is not
    # authority to issue provisioning profiles. Match the service role, not just that chain.
    name = subject.strip().removeprefix("subject=").strip()
    fields, start, escaped = [], 0, False
    for index, character in enumerate(name):
        if escaped:
            escaped = False
        elif character == "\\":
            escaped = True
        elif character == ",":
            fields.append(name[start:index])
            start = index + 1
    fields.append(name[start:])
    names = [field for field in fields if field.startswith("CN=")]
    return names == ["CN=Apple iPhone OS Provisioning Profile Signing"]


def mobile_bundle(app, *, team, identifier, channel, apns, migration, root):
    info = plist(app / "Info.plist")
    supported = info.get("CFBundleSupportedPlatforms", [])
    require(supported == (["iPhoneOS"] if root else ["WatchOS"]), "Unexpected device platform or simulator artifact")
    entitlements, _ = evidence(app, team, identifier)
    # security cms can import certificates into the default Keychain. Verify CMS against
    # read-only system Apple roots instead; inspection must not mutate the person's Keychain.
    with tempfile.TemporaryDirectory(prefix="axo-profile-evidence-") as directory:
        roots, _ = run("/usr/bin/security", "find-certificate", "-a", "-p", "-c", "Apple Root CA",
                       "/System/Library/Keychains/SystemRootCertificates.keychain")
        require(b"BEGIN CERTIFICATE" in roots, "System Apple trust roots are unavailable")
        root_file = Path(directory) / "apple-roots.pem"
        root_file.write_bytes(roots)
        signer_file = Path(directory) / "profile-signer.pem"
        raw, _ = run("/usr/bin/openssl", "smime", "-verify", "-inform", "DER", "-purpose", "any",
                     "-CAfile", str(root_file), "-signer", str(signer_file), "-in", str(app / "embedded.mobileprovision"))
        require(signer_file.read_bytes().count(b"BEGIN CERTIFICATE") == 1, "Ambiguous provisioning signer")
        subject, _ = run("/usr/bin/openssl", "x509", "-in", str(signer_file), "-noout", "-subject", "-nameopt", "RFC2253")
        require(is_provisioning_signer(subject.decode("utf-8", errors="replace")),
                "Profile was not signed by the Apple provisioning service")
    try:
        profile = plistlib.loads(raw)
        require(isinstance(profile, dict), "Malformed provisioning profile")
    except (ValueError, plistlib.InvalidFileException):
        raise GateError("Provisioning profile could not be decoded") from None
    mobile_policy(info, entitlements, profile, bundle_id=identifier, team=team, channel=channel,
                  apns=apns, migration=migration)
    # A valid Apple signature alone is insufficient: it must use a certificate in this profile.
    with tempfile.TemporaryDirectory(prefix="axo-signature-evidence-") as directory:
        prefix = Path(directory) / "certificate"
        run("/usr/bin/codesign", "--display", "--extract-certificates=" + str(prefix), str(app))
        require((Path(str(prefix) + "0")).read_bytes() in profile.get("DeveloperCertificates", []),
                "Signing certificate is not authorized by the embedded profile")


def unpack_ipa(path, directory):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) <= 50_000 and sum(entry.file_size for entry in entries) <= 1024 ** 3, "IPA exceeds inspection limits")
        names = set()
        for entry in entries:
            parts = PurePosixPath(entry.filename)
            require(not parts.is_absolute() and ".." not in parts.parts and "\\" not in entry.filename and
                    entry.filename.rstrip("/") == parts.as_posix(),
                    "Unsafe IPA path")
            require(not stat.S_ISLNK(entry.external_attr >> 16), "Unexpected IPA symlink")
            require(entry.filename not in names, "Duplicate IPA entry")
            names.add(entry.filename)
        archive.extractall(directory)
    apps = list((Path(directory) / "Payload").glob("*.app"))
    require(len(apps) == 1, "IPA must contain exactly one root app")
    return apps[0]


def inspect(args, config):
    apple = config["apple"]
    team = apple["team"]
    require(bool(re.fullmatch(r"[A-Z0-9]{10}", team)), "Invalid configured signing team")
    for identifier in apple["bundle_ids"].values():
        require(bool(re.fullmatch(r"[A-Za-z0-9.-]+", identifier)), "Invalid configured bundle identity")
    if args.channel == "developer-id":
        require(not args.existing_installation and not args.migration and not args.require_apns, "Incompatible Mac preflight options")
        app = args.artifact
        info = plist(app / "Contents" / "Info.plist")
        require(info.get("CFBundleSupportedPlatforms") == ["MacOSX"], "Developer ID requires a Mac app bundle")
        identifier = apple["bundle_ids"]["mac"]
        entitlements, details = evidence(app, team, identifier, developer_id=True)
        developer_id_policy(info, entitlements, details, bundle_id=identifier)
        # Verify embedded executable code too; a root Developer ID signature must not hide a
        # development/ad-hoc helper. Preserve bundled relative symlinks but reject escaping ones.
        magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
        for path in app.rglob("*"):
            if path.is_symlink():
                require(path.resolve(strict=True).is_relative_to(app.resolve()), "Bundle symlink escapes the app")
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) not in magic:
                    continue
            child_entitlements, child_details = evidence(path, team, developer_id=True)
            developer_id_code_policy(child_entitlements, child_details)
        return
    require(args.channel == "development" or not args.existing_installation, "Old-identity installs are development-only")
    require(not args.migration or args.channel == "development", "Migration profiles are development-only")
    identifier = "dev.leostera.axo.phone" if args.existing_installation else apple["bundle_ids"]["phone"]
    watch = identifier + ".watchkitapp" if args.existing_installation else apple["bundle_ids"]["watch"]
    expected = {watch, watch + ".complications"}
    with tempfile.TemporaryDirectory(prefix="axo-ipa-preflight-") as directory:
        app = unpack_ipa(args.artifact, directory)
        mobile_bundle(app, team=team, identifier=identifier, channel=args.channel, apns=args.require_apns, migration=args.migration, root=True)
        children = sorted(path for path in app.rglob("*") if path.suffix in (".app", ".appex") and path.is_dir())
        found = set()
        for child in children:
            child_id = plist(child / "Info.plist").get("CFBundleIdentifier")
            require(child_id in expected and child_id not in found, "Unexpected nested app identity")
            found.add(child_id)
            mobile_bundle(child, team=team, identifier=child_id, channel=args.channel, apns=False, migration=False, root=False)
        require(found == expected, "Missing watch app or complication")


def main():
    import json
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("--channel", required=True, choices=["development", "ad-hoc", "app-store-connect", "developer-id"])
    parser.add_argument("--existing-installation", action="store_true")
    parser.add_argument("--require-apns", action="store_true")
    parser.add_argument("--migration", action="store_true")
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    try:
        inspect(args, json.loads(args.config.read_text()))
    except (GateError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        # Only our gate messages are safe to publish; parser/OS errors can include private paths.
        message = str(error) if isinstance(error, GateError) else "Signing evidence is missing or malformed"
        parser.exit(1, "distribution preflight failed: " + message + "\n")
    print("distribution signing preflight passed (" + args.channel + "). No notarization, upload or installation performed.")
    if args.existing_installation:
        print("Existing watch/widget development Keychain namespaces are retained; this is not canonical migration proof.")


if __name__ == "__main__":
    main()
