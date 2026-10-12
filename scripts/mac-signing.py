"""Select an existing signing identity; never install certificates or fall back to ad hoc."""
from __future__ import annotations
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple


class SigningIdentity(NamedTuple):
    fingerprint: str
    kind: str


def select_identity(output: str, requested: str | None) -> SigningIdentity:
    identities = []
    for line in output.splitlines():
        match = re.fullmatch(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(Apple Development|Developer ID Application):[^"\n]+\([A-Z0-9]{10}\)"\s*', line)
        if match:
            identity = SigningIdentity(match[1].upper(), match[2])
            if identity not in identities:
                identities.append(identity)
    if requested:
        identities = [identity for identity in identities if identity.fingerprint == requested.upper()]
    if len(identities) != 1:
        raise ValueError("Axo requires one valid Apple Development or Developer ID Application signing identity. Select its fingerprint with AXO_MAC_SIGNING_IDENTITY; ad-hoc signing is not supported for installed background service builds.")
    return identities[0]


def installed_identity() -> SigningIdentity:
    output = subprocess.run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
                            check=True, capture_output=True, text=True, timeout=15)
    return select_identity(output.stdout, os.environ.get("AXO_MAC_SIGNING_IDENTITY"))


def verified_team(path: Path, identity: SigningIdentity, identifier: str) -> str:
    output = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(path)],
                            check=True, capture_output=True, text=True, timeout=15)
    facts = dict(line.split("=", 1) for line in output.stderr.splitlines() if "=" in line)
    team = facts.get("TeamIdentifier", "")
    authority = any(line.startswith("Authority=" + identity.kind + ":") for line in output.stderr.splitlines())
    if not re.fullmatch(r"[A-Z0-9]{10}", team) or not authority or facts.get("Identifier") != identifier or facts.get("Signature") == "adhoc":
        raise ValueError("Package signing identity or identifier mismatch")
    return team


def sign(app: Path, identity: SigningIdentity) -> None:
    helper = app / "Contents/Helpers/axod"
    # Sign nested code first. Resource files and the installed Pi extension are
    # sealed by the outer bundle, not treated as executables.
    for library in sorted(app.rglob("*.dylib")):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
                        "--timestamp=none", str(library)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
                    "--identifier", "dev.leostera.axo.axod", "--timestamp=none", str(helper)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity.fingerprint,
                    "--timestamp=none", str(app)], check=True)
    # A development certificate's display-name suffix is a person identifier,
    # not necessarily its team. Use the actual CodeDirectory team instead.
    team = verified_team(helper, identity, "dev.leostera.axo.axod")
    if verified_team(app, identity, "dev.leostera.axo.mac") != team:
        raise ValueError("Axo and Axod must be signed by the same team")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Signed Axo and Axod with team", team)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["check"]:
            print("Signing identity:", installed_identity().kind)
        elif len(sys.argv) == 3 and sys.argv[1] == "sign":
            sign(Path(sys.argv[2]), installed_identity())
        else:
            raise ValueError("Usage: mac-signing.py check | sign /staged/Axo.app")
    except (ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
