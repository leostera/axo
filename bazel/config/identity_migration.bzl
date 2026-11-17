"""Explicit temporary staging switch; it never authorizes installation or account changes."""

def _flag_impl(_ctx):
    return []

identity_preservation_probe_flag = rule(
    implementation = _flag_impl,
    build_setting = config.bool(flag = True),
)
