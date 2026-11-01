"""`@axo_config`: config.json, config.local.json and what this Mac can do (RFD0021).

The repository merges `config.local.json` (ignored by git) over `config.json`, checks this Mac for
the optional pieces of the build (a signing identity for the team, the phone's provisioning
profile, the Pi CLI) and generates:

- `defs.bzl`: `AXO` (the merged config), `CAN` (what this Mac can do), `MACHINE` (paths the
  build actions that write into the workspace need) and `REASONS` (why a piece falls back).
- `axod.env`: the build number axod reports.
- `mac.plist`: `AXODBuildNumber` and `AXOGitCommit` for the Mac app's Info.plist.
- `machine.txt`: the facts above, for the build report.
- `install_state.txt`: which of the files the build writes into the workspace exist.

It reruns when either config file, the keychain, the provisioning profile folders or git HEAD
change. Whether the phone is plugged in is not checked here; the install action checks it.

`@axo_files` lists the files under apple/ and crates/ (`apple_files.txt`, `crates_files.txt`), so
the Xcode project and rust-project.json are generated again when one is added, moved or removed.
It is its own repository because it reruns on every edit there, which should not probe the
keychain again.
"""

# Every key config.json must have, with its type. config.local.json may override any of them and
# may add the keys in _LOCAL_SCHEMA.
_SCHEMA = {
    "version": "string",
    "builds": {"mac": "int", "phone": "int", "axod": "int"},
    "apple": {
        "team": "string",
        "macos_min": "string",
        "ios_min": "string",
        "bundle_ids": {
            "mac": "string",
            "mac_ui_tests": "string",
            "mac_visual_tests": "string",
            "mac_mascot_tests": "string",
            "phone": "string",
        },
        "phone_profile": "string",
        "simulator": {"device": "string", "os": "string"},
    },
    "dist": {"mac_app": "string"},
    "publish": {"bucket": "string", "url": "string"},
}

_LOCAL_SCHEMA = {
    "phone": {"device": "string", "install": "bool"},
    "signing": {"identity": "string"},
    "pi": "string",
}

_TYPES = {"string": "string", "int": "int", "bool": "bool"}

def _check(value, schema, where, required):
    """Fails on a missing key (when `required`), an unknown key or a wrong type."""

    # Starlark has no recursion: walk the nested objects with a work list.
    pending = [(value, schema, where)]
    for _ in range(1000):
        if not pending:
            return
        value, schema, where = pending.pop()
        if type(schema) == "dict":
            if type(value) != "dict":
                fail("%s must be an object" % where)
            for key in value:
                if key not in schema:
                    fail("%s has an unknown key %r" % (where, key))
                pending.append((value[key], schema[key], "%s.%s" % (where, key)))
            if required:
                for key in schema:
                    if key not in value:
                        fail("%s is missing %r" % (where, key))
        elif type(value) != _TYPES[schema]:
            fail("%s must be a %s, not %s" % (where, schema, type(value)))
    fail("%s nests too deeply" % where)

def _merge(base, override):
    """`override` merged over `base`, object by object (three levels are enough here)."""
    merged = dict(base)
    for key, value in override.items():
        if type(value) == "dict" and type(merged.get(key)) == "dict":
            inner = dict(merged[key])
            for key2, value2 in value.items():
                if type(value2) == "dict" and type(inner.get(key2)) == "dict":
                    innermost = dict(inner[key2])
                    innermost.update(value2)
                    inner[key2] = innermost
                else:
                    inner[key2] = value2
            merged[key] = inner
        else:
            merged[key] = value
    return merged

def _run(rctx, args):
    """Runs a command; returns its stdout, or None when it fails or is missing."""
    result = rctx.execute(args, timeout = 30, quiet = True)
    if result.return_code != 0:
        return None
    return result.stdout

def _certificate_team(rctx, sha1):
    """The team (the subject's OU) of the keychain certificate with this SHA-1."""
    pem = _run(rctx, ["/usr/bin/security", "find-certificate", "-a", "-Z", "-p"])
    if pem == None:
        return None

    # find-certificate -Z prints "SHA-1 hash: <sha1>" before each certificate's PEM.
    marker = "SHA-1 hash: " + sha1
    start = pem.find(marker)
    if start < 0:
        return None
    begin = pem.find("-----BEGIN CERTIFICATE-----", start)
    end = pem.find("-----END CERTIFICATE-----", begin)
    if begin < 0 or end < 0:
        return None
    rctx.file("cert.pem", pem[begin:end + len("-----END CERTIFICATE-----")] + "\n")
    subject = _run(rctx, ["/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "multiline", "-in", "cert.pem"])
    rctx.delete("cert.pem")
    if subject == None:
        return None
    for line in subject.splitlines():
        line = line.strip()
        if line.startswith("organizationalUnitName"):
            return line.split("=", 1)[1].strip()
    return None

def _signing_identity(rctx, config):
    """The identity to sign the Mac app with, or (None, reason)."""
    home = rctx.os.environ.get("HOME", "")
    rctx.watch(home + "/Library/Keychains/login.keychain-db")
    listing = _run(rctx, ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    if listing == None:
        return None, "the keychain could not be read"
    identities = []
    for line in listing.splitlines():
        parts = line.strip().split(" ", 2)
        if len(parts) == 3 and parts[0].endswith(")") and len(parts[1]) == 40:
            identities.append(struct(sha1 = parts[1], name = parts[2].strip('"')))

    wanted = config.get("signing", {}).get("identity")
    team = config["apple"]["team"]
    candidates = []
    for identity in identities:
        if wanted and wanted not in (identity.sha1, identity.name):
            continue
        if _certificate_team(rctx, identity.sha1) == team:
            candidates.append(identity)
    if not candidates:
        if wanted:
            return None, "signing.identity %r is not a valid identity of team %s" % (wanted, team)
        return None, "no signing identity of team %s in the keychain" % team

    # Prefer a development identity: the app is signed for development, not notarized.
    candidates = sorted(candidates, key = lambda identity: (not identity.name.startswith("Apple Development"), identity.name, identity.sha1))
    return candidates[0], None

def _phone_profile(rctx, config):
    """Whether the phone's provisioning profile is installed, and why not."""
    home = rctx.os.environ.get("HOME", "")
    name = config["apple"]["phone_profile"]
    for folder in [
        home + "/Library/Developer/Xcode/UserData/Provisioning Profiles",
        home + "/Library/MobileDevice/Provisioning Profiles",
    ]:
        directory = rctx.path(folder)
        if not directory.exists:
            rctx.watch(folder)
            continue
        for profile in directory.readdir(watch = "yes"):
            if not profile.basename.endswith(".mobileprovision"):
                continue
            rctx.watch(profile)
            decoded = _run(rctx, ["/usr/bin/security", "cms", "-D", "-i", str(profile)])
            if decoded == None:
                continue
            rctx.file("profile.plist", decoded)
            profile_name = _run(rctx, ["/usr/bin/plutil", "-extract", "Name", "raw", "-o", "-", "profile.plist"])
            rctx.delete("profile.plist")
            if profile_name != None and profile_name.strip() == name:
                return True, None
    return False, "no provisioning profile named %r (Xcode makes it the first time it signs the phone app)" % name

def _git_commit(rctx, workspace):
    """The checked-out commit, rerunning whenever HEAD moves."""
    git_dir = _run(rctx, ["/usr/bin/git", "-C", str(workspace), "rev-parse", "--absolute-git-dir"])
    common_dir = _run(rctx, ["/usr/bin/git", "-C", str(workspace), "rev-parse", "--path-format=absolute", "--git-common-dir"])
    if git_dir == None or common_dir == None:
        return "unknown"
    git_dir = git_dir.strip()
    common_dir = common_dir.strip()
    rctx.watch(git_dir + "/HEAD")
    rctx.watch(common_dir + "/packed-refs")
    ref = _run(rctx, ["/usr/bin/git", "-C", str(workspace), "symbolic-ref", "-q", "HEAD"])
    if ref != None:
        rctx.watch(common_dir + "/" + ref.strip())
    commit = _run(rctx, ["/usr/bin/git", "-C", str(workspace), "rev-parse", "--short=8", "HEAD"])
    return commit.strip() if commit != None else "unknown"

def _starlark(value):
    """Renders a scalar as a Starlark literal."""
    if value == None:
        return "None"
    if type(value) == "bool":
        return "True" if value else "False"
    return repr(value)

def _axo_config_impl(rctx):
    workspace = rctx.path(Label("@@//:MODULE.bazel")).dirname
    shared_path = workspace.get_child("config.json")
    local_path = workspace.get_child("config.local.json")
    rctx.watch(shared_path)
    rctx.watch(local_path)

    shared = json.decode(rctx.read(shared_path))
    _check(shared, _SCHEMA, "config.json", required = True)
    local = {}
    if local_path.exists:
        local = json.decode(rctx.read(local_path))
        _check(local, _merge(_SCHEMA, _LOCAL_SCHEMA), "config.local.json", required = False)
    config = _merge(shared, local)
    for key, value in config["builds"].items():
        if value < 1:
            fail("builds.%s must be a positive integer" % key)

    reasons = {}

    identity, reason = _signing_identity(rctx, config)
    if reason:
        reasons["sign"] = reason

    has_profile, reason = _phone_profile(rctx, config)
    if reason:
        reasons["phone_device"] = reason

    phone = config.get("phone", {})
    phone_install = has_profile and phone.get("install", False) and bool(phone.get("device"))
    if not phone.get("install", False):
        reasons["phone_install"] = "off (set phone.install in config.local.json)"
    elif not phone.get("device"):
        reasons["phone_install"] = "phone.device is not set in config.local.json"
    elif not has_profile:
        reasons["phone_install"] = "the phone app cannot be signed: " + reasons["phone_device"]

    pi = config.get("pi") or rctx.which("pi")
    if pi == None:
        reasons["pi"] = "the Pi CLI is not on PATH (or set pi in config.local.json)"

    bazel = rctx.which("bazel") or rctx.which("bazelisk")
    commit = _git_commit(rctx, workspace)

    # <output_base>/external/<this repository>
    output_base = rctx.path(".").dirname.dirname

    machine = {
        "workspace": str(workspace),
        "output_base": str(output_base),
        "bazel": str(bazel) if bazel else None,
        "home": rctx.os.environ.get("HOME", ""),
        "user": rctx.os.environ.get("USER", ""),
        "pi": str(pi) if pi else None,
        "signing_identity": identity.sha1 if identity else None,
        "signing_name": identity.name if identity else None,
        "git_commit": commit,
    }
    can = {
        "sign": identity != None,
        "phone_device": has_profile,
        "phone_install": phone_install,
        "pi": pi != None,
    }

    rctx.file("defs.bzl", """\"\"\"Generated by //bazel/config:extension.bzl from config.json and config.local.json.\"\"\"

AXO = json.decode({axo})

CAN = struct({can})

MACHINE = struct({machine})

REASONS = json.decode({reasons})
""".format(
        axo = repr(json.encode_indent(config, indent = "    ")),
        can = ", ".join(["%s = %s" % (k, _starlark(v)) for k, v in can.items()]),
        machine = ", ".join(["%s = %s" % (k, _starlark(v)) for k, v in machine.items()]),
        reasons = repr(json.encode(reasons)),
    ))

    rctx.file("axod.env", "AXO_BUILD_NUMBER=%d\n" % config["builds"]["axod"])

    rctx.file("mac.plist", """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AXODBuildNumber</key>
    <string>{axod}</string>
    <key>AXOGitCommit</key>
    <string>{commit}</string>
</dict>
</plist>
""".format(axod = config["builds"]["axod"], commit = commit))

    lines = ["version %s, builds: mac %d, phone %d, axod %d, commit %s" % (
        config["version"],
        config["builds"]["mac"],
        config["builds"]["phone"],
        config["builds"]["axod"],
        commit,
    )]
    if "pi" in reasons:
        lines.append("pi: " + reasons["pi"])
    rctx.file("machine.txt", "\n".join(lines) + "\n")

    # The build writes these into the workspace. Each install action depends on this file, which
    # changes when one of them appears or disappears, so deleting one brings it back.
    state = []
    for name, path in [
        ("mac_app", config["dist"]["mac_app"] + "/Contents/Info.plist"),
        ("xcodeproj", "apple/Axo.xcodeproj/project.pbxproj"),
        ("rust_project", "rust-project.json"),
    ]:
        marker = workspace.get_child(path)
        rctx.watch(marker)
        state.append("%s %s" % (name, "present" if marker.exists else "absent"))
    rctx.file("install_state.txt", "\n".join(state) + "\n")

    rctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["axod.env", "defs.bzl", "install_state.txt", "mac.plist", "machine.txt"])
""")

_axo_config = repository_rule(
    implementation = _axo_config_impl,
    doc = "config.json merged with config.local.json, and what this Mac can do.",
)

# Not part of what the projects are made from: the Xcode project itself, and the state of Swift
# Package Manager, Xcode and Cargo.
_NOT_SOURCES = ["Axo.xcodeproj", ".build", ".swiftpm", "xcuserdata", "target"]

def _axo_files_impl(rctx):
    workspace = rctx.path(Label("@@//:MODULE.bazel")).dirname
    prune = []
    for name in _NOT_SOURCES:
        prune += ["-name", name, "-prune", "-o"]
    for tree in ["apple", "crates"]:
        root = workspace.get_child(tree)
        rctx.watch_tree(root)
        found = rctx.execute(["/usr/bin/find", "."] + prune + ["-type", "f", "-print"], working_directory = str(root))
        files = sorted([line for line in found.stdout.splitlines() if line])
        rctx.file(tree + "_files.txt", "\n".join(files) + "\n")
    rctx.file("BUILD.bazel", """exports_files(["apple_files.txt", "crates_files.txt"], visibility = ["//visibility:public"])\n""")

_axo_files = repository_rule(
    implementation = _axo_files_impl,
    doc = "The paths of the files under apple/ and crates/, for regenerating the editor projects when they change.",
)

def _axo_config_extension_impl(module_ctx):
    _axo_config(name = "axo_config")
    _axo_files(name = "axo_files")
    return module_ctx.extension_metadata(reproducible = False)

axo_config = module_extension(implementation = _axo_config_extension_impl)
