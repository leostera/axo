load("//:ghostty_pin.bzl", "download_zig_and_ghostty")

def _ghostty_vt_repository_impl(ctx):
    zig, source = download_zig_and_ghostty(ctx)

    # Only libghostty-vt: no renderer, fonts or app frameworks, so it builds in about a minute
    # and is independent of the app's GhosttyKit build and its patches.
    result = ctx.execute(
        [
            str(zig),
            "build",
            "-Doptimize=ReleaseFast",
            "-Demit-lib-vt=true",
            "-Demit-xcframework=false",
        ],
        timeout = 3600,
        working_directory = str(source),
    )
    if result.return_code != 0:
        fail("Building libghostty-vt failed (exit %s):\n%s\n%s" % (result.return_code, result.stdout, result.stderr))

    ctx.symlink("source/zig-out/lib/libghostty-vt.a", "lib/libghostty-vt.a")
    ctx.symlink("source/zig-out/include", "include")
    ctx.file("BUILD.bazel", """load("@rules_cc//cc:defs.bzl", "cc_import")

package(default_visibility = ["//visibility:public"])

cc_import(
    name = "ghostty_vt",
    static_library = "lib/libghostty-vt.a",
    hdrs = glob(["include/ghostty/**/*.h"]),
)
""")

ghostty_vt_repository = repository_rule(
    implementation = _ghostty_vt_repository_impl,
    doc = "Builds libghostty-vt, Ghostty's headless terminal library, at the pinned Ghostty commit.",
    local = False,
    environ = ["HOME", "SSL_CERT_FILE", "ZIG_GLOBAL_CACHE_DIR"],
)
