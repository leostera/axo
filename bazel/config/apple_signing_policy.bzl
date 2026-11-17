"""Identity matching and explicit, bundle-scoped installation consent."""

def profile_matches(profile, team, bundle_id):
    # App Identifier Prefix can differ from Team ID: never infer one from the other.
    return bool(profile.prefix) and profile.team == team and profile.application_id == profile.prefix + "." + bundle_id

def phone_installation(phone, bundle_id, profiles_ready, profile_reason):
    if not phone.get("install", False):
        return struct(enabled = False, reason = "off (set phone.install in config.local.json)")
    if phone.get("install_bundle_id") != bundle_id:
        return struct(enabled = False, reason = "off: phone.install_bundle_id must explicitly match " + bundle_id)
    if not phone.get("device"):
        return struct(enabled = False, reason = "phone.device is not set in config.local.json")
    if not profiles_ready:
        return struct(enabled = False, reason = "the phone app cannot be signed: " + profile_reason)
    return struct(enabled = True, reason = None)
