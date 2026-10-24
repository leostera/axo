def _ghostty_repository_impl(ctx):
    if ctx.os.name != "mac os x":
        fail("GhosttyKit is currently built for macOS hosts only")

    if ctx.os.arch == "aarch64":
        zig_url = "https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz"
        zig_sha256 = "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489"
        zig_dir = "zig-aarch64-macos-0.16.0"
    elif ctx.os.arch == "x86_64":
        zig_url = "https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz"
        zig_sha256 = "0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7"
        zig_dir = "zig-x86_64-macos-0.16.0"
    else:
        fail("Unsupported macOS host architecture for Zig: %s" % ctx.os.arch)

    ctx.download_and_extract(
        url = zig_url,
        sha256 = zig_sha256,
        strip_prefix = zig_dir,
        output = "zig-toolchain",
    )
    ctx.download_and_extract(
        url = "https://github.com/ghostty-org/ghostty/archive/81598385d608dda4946093d6d6a234d204a2f225.tar.gz",
        sha256 = "1bb165d1e9458c8694370039cc1a8f2a2958929760bb80f6251499158ad6b694",
        strip_prefix = "ghostty-81598385d608dda4946093d6d6a234d204a2f225",
        output = "source",
    )

    # Axo carries a small patch set on the pinned commit; see third_party/ghostty/README.md.
    for patch in ctx.attr.patches:
        ctx.patch(patch, strip = 1)

    zig = ctx.path("zig-toolchain/zig")
    source = ctx.path("source")
    result = ctx.execute(
        [
            str(zig),
            "build",
            "-Doptimize=ReleaseFast",
            "-Demit-themes=false",
            "-Di18n=false",
            "-Demit-xcframework=true",
            "-Demit-macos-app=false",
        ],
        timeout = 3600,
        working_directory = str(source),
    )
    if result.return_code != 0:
        fail("Building GhosttyKit failed (exit %s):\n%s\n%s" % (result.return_code, result.stdout, result.stderr))

    ctx.symlink("source/macos/GhosttyKit.xcframework", "GhosttyKit.xcframework")
    ctx.symlink("source/zig-out/share/ghostty", "ghostty-resources")
    ctx.symlink("source/zig-out/share/terminfo", "terminfo")
    ctx.file("BUILD.bazel", """load(\"@rules_apple//apple:apple.bzl\", \"apple_static_xcframework_import\")

package(default_visibility = [\"//visibility:public\"])

apple_static_xcframework_import(
    name = \"GhosttyKit\",
    xcframework_imports = glob([\"GhosttyKit.xcframework/**\"]),
    sdk_frameworks = [
        \"AppKit\",
        \"ApplicationServices\",
        \"Carbon\",
        \"CoreGraphics\",
        \"CoreText\",
        \"Foundation\",
        \"GameController\",
        \"IOKit\",
        \"IOSurface\",
        \"Metal\",
        \"MetalKit\",
        \"QuartzCore\",
        \"UniformTypeIdentifiers\",
    ],
    sdk_dylibs = [\"c++\", \"z\"],
)

filegroup(
    name = \"resources\",
    srcs = glob([\"ghostty-resources/**\"]),
)

filegroup(
    name = \"terminfo\",
    srcs = glob([\"terminfo/**\"]),
)
""")

ghostty_repository = repository_rule(
    implementation = _ghostty_repository_impl,
    doc = "Builds a pinned GhosttyKit XCFramework and its runtime resources with the pinned Zig toolchain.",
    local = False,
    attrs = {
        "patches": attr.label_list(
            default = [Label("//third_party/ghostty:0001-external-terminal-io.patch")],
            doc = "Patches applied to the pinned Ghostty source before building.",
        ),
    },
    environ = ["HOME", "SSL_CERT_FILE", "ZIG_GLOBAL_CACHE_DIR"],
)
