load("//:ghostty_pin.bzl", "download_zig_and_ghostty")

def _ghostty_repository_impl(ctx):
    zig, source = download_zig_and_ghostty(ctx)

    # Axo carries a small patch set on the pinned commit; see third_party/ghostty/README.md.
    for patch in ctx.attr.patches:
        ctx.patch(patch, strip = 1)

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
