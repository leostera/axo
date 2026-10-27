"""The pinned Ghostty commit and Zig toolchain, shared by every rule that builds from Ghostty."""

GHOSTTY_COMMIT = "81598385d608dda4946093d6d6a234d204a2f225"
GHOSTTY_SHA256 = "1bb165d1e9458c8694370039cc1a8f2a2958929760bb80f6251499158ad6b694"

_ZIG = {
    "aarch64": struct(
        url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz",
        sha256 = "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
        strip_prefix = "zig-aarch64-macos-0.16.0",
    ),
    "x86_64": struct(
        url = "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz",
        sha256 = "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7",
        strip_prefix = "zig-x86_64-macos-0.16.0",
    ),
}

def download_zig_and_ghostty(ctx):
    """Extracts the pinned Zig toolchain and Ghostty source; returns (zig, source) paths."""
    if ctx.os.name != "mac os x":
        fail("Ghostty is currently built for macOS hosts only")
    zig = _ZIG.get(ctx.os.arch)
    if zig == None:
        fail("Unsupported macOS host architecture for Zig: %s" % ctx.os.arch)
    ctx.download_and_extract(
        url = zig.url,
        sha256 = zig.sha256,
        strip_prefix = zig.strip_prefix,
        output = "zig-toolchain",
    )
    ctx.download_and_extract(
        url = "https://github.com/ghostty-org/ghostty/archive/%s.tar.gz" % GHOSTTY_COMMIT,
        sha256 = GHOSTTY_SHA256,
        strip_prefix = "ghostty-%s" % GHOSTTY_COMMIT,
        output = "source",
    )
    return ctx.path("zig-toolchain/zig"), ctx.path("source")
