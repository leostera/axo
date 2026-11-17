load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":apple_signing_policy.bzl", "phone_installation", "profile_matches")

def _identity_policy_test(ctx):
    env = unittest.begin(ctx)
    root = "dev.leostera.axo"
    valid = struct(prefix = "APPSEED", team = "TEAM", application_id = "APPSEED." + root)
    asserts.true(env, profile_matches(valid, "TEAM", root))
    asserts.false(env, profile_matches(valid, "OTHERTEAM", root))
    asserts.false(env, profile_matches(valid, "TEAM", root + ".phone"))
    asserts.false(env, profile_matches(struct(prefix = "APPSEED", team = "TEAM", application_id = "APPSEED.*"), "TEAM", root))
    asserts.false(env, profile_matches(struct(prefix = None, team = "TEAM", application_id = "APPSEED." + root), "TEAM", root))
    base = {"install": True, "device": "owned-test-device"}
    asserts.false(env, phone_installation(base, root, True, "").enabled)
    pinned = dict(base, install_bundle_id = root)
    asserts.true(env, phone_installation(pinned, root, True, "").enabled)
    asserts.false(env, phone_installation(dict(base, install_bundle_id = root + ".phone"), root, True, "").enabled)
    asserts.false(env, phone_installation(dict(pinned, install = False), root, True, "").enabled)
    asserts.false(env, phone_installation(dict(pinned, device = ""), root, True, "").enabled)
    missing = phone_installation(pinned, root, False, "missing root profile")
    asserts.false(env, missing.enabled)
    asserts.true(env, "missing root profile" in missing.reason)
    return unittest.end(env)

apple_signing_policy_test = unittest.make(_identity_policy_test)
