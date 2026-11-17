"""Profile-derived Info plists for explicitly requested device preservation probes."""

_PROBE = "//bazel/config:identity_preservation_probe_enabled"

def preservation_probe_info(name, profile, bundle_id, mode, team):
    native.genrule(
        name = name,
        srcs = select({_PROBE: [profile], "//conditions:default": []}),
        tools = [
            "//bazel/apple:preservation_probe_info.py",
            "//bazel/apple:distribution_preflight.py",
        ],
        outs = [name + ".plist"],
        cmd = select({
            _PROBE: '/usr/bin/python3 -B "$(location //bazel/apple:preservation_probe_info.py)" "$(location //bazel/apple:distribution_preflight.py)" --profile $(location %s) --bundle-id "%s" --mode "%s" --team "%s" --output "$@"' % (profile, bundle_id, mode, team),
            "//conditions:default": "printf '%s' '<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>' > $@",
        }),
        # Development profiles must stay on this host, not a remote executor/cache.
        tags = ["manual", "no-remote"],
    )
