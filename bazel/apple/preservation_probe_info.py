"""Generate only public probe metadata from a verified local development profile."""
import argparse
import datetime as dt
import importlib.util
from pathlib import Path
import plistlib
import re
import sys


def probe_info(profile, *, bundle_id, mode, team):
    pairs = {
        "source": {"dev.leostera.axo.phone", "dev.leostera.axo.phone.watchkitapp"},
        "destination": {"dev.leostera.axo", "dev.leostera.axo.watch"},
    }
    if mode not in pairs or bundle_id not in pairs[mode]:
        raise ValueError("Unexpected preservation role/identity")
    if profile.get("TeamIdentifier") != [team]:
        raise ValueError("Unexpected provisioning team")
    prefixes = profile.get("ApplicationIdentifierPrefix")
    if not isinstance(prefixes, list) or len(prefixes) != 1 or not isinstance(prefixes[0], str) or not re.fullmatch(r"[A-Z0-9]{10}", prefixes[0]):
        raise ValueError("Missing or ambiguous profile prefix")
    prefix = prefixes[0] + "."
    entitlements = profile.get("Entitlements", {})
    if not isinstance(entitlements, dict):
        raise ValueError("Malformed provisioning entitlements")
    group = prefix + "dev.leostera.axo.migration"
    if entitlements.get("application-identifier") != prefix + bundle_id or entitlements.get("com.apple.developer.team-identifier") != team:
        raise ValueError("Provisioning identity mismatch")
    devices = profile.get("ProvisionedDevices")
    if entitlements.get("get-task-allow") is not True or not isinstance(devices, list) or not devices or not all(isinstance(device, str) for device in devices) or profile.get("ProvisionsAllDevices", False):
        raise ValueError("Preservation probes require device-limited development provisioning")
    groups = entitlements.get("keychain-access-groups", [])
    if not isinstance(groups, list) or not all(isinstance(value, str) for value in groups) or (group not in groups and prefix + "*" not in groups):
        raise ValueError("Profile does not authorize the migration group")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, dt.datetime):
        raise ValueError("Missing profile expiry")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    if expiry <= dt.datetime.now(dt.timezone.utc):
        raise ValueError("Profile has expired")
    platforms = profile.get("Platform", [])
    if not isinstance(platforms, list) or not all(isinstance(value, str) for value in platforms) or not any(value in ("iOS", "watchOS") for value in platforms):
        raise ValueError("Unexpected preservation platform")
    return {"AXOIdentityProbeMode": mode, "AXOIdentityProbeAccessGroup": group}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("policy", type=Path)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--mode", choices=["source", "destination"], required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    phase = "load-policy"
    try:
        spec = importlib.util.spec_from_file_location("axo_distribution_policy", args.policy)
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)
        phase = "verify-profile"
        if not args.profile.is_file():
            raise policy.GateError("Selected profile file is unavailable")
        profile = policy.read_provisioning_profile(args.profile)
        phase = "validate-metadata"
        info = probe_info(profile, bundle_id=args.bundle_id, mode=args.mode, team=args.team)
        phase = "write-metadata"
        args.output.write_bytes(plistlib.dumps(info))
    except Exception as error:
        # probe_info's ValueErrors are fixed policy messages; all other diagnostics stay private.
        safe_policy_error = phase == "verify-profile" and isinstance(error, policy.GateError)
        reason = str(error) if safe_policy_error or (phase == "validate-metadata" and type(error) is ValueError) else phase
        parser.exit(1, "Preservation metadata failed: " + reason + ".\n")


if __name__ == "__main__":
    main()
