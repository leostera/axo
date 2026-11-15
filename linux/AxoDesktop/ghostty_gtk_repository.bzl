load("//:ghostty_pin.bzl", "download_zig_and_ghostty")

def _implementation(ctx):
    if ctx.os.name != "linux":
        fail("AxoDesktop's GTK prototype must be built on Linux")
    zig, source = download_zig_and_ghostty(ctx)
    for patch in ctx.attr.patches:
        ctx.patch(patch, strip = 1)
    ctx.file("source/build.zig", ctx.read(ctx.attr.build_file))
    ctx.file("source/src/axo_gtk_bridge.zig", ctx.read(ctx.attr.bridge_file))
    result = ctx.execute([
        str(zig), "build", "-j8",
        # Keep native compilation artifacts across a failed repository fetch too.
        "--cache-dir", ctx.getenv("HOME") + "/.cache/axo-ghostty-gtk",
        "-Doptimize=ReleaseFast", "-Dapp-runtime=gtk",
        "-Demit-themes=false", "-Di18n=false", "-Dsentry=false",
    ], working_directory = str(source), timeout = 3600)
    if result.return_code:
        fail("Building Ghostty GTK bridge failed:\n%s\n%s" % (result.stdout[-12000:], result.stderr[-16000:]))
    ctx.symlink("source/zig-out/lib", "lib")
    ctx.symlink("source/zig-out/share", "share")
    ctx.file("runtime.marker", "AxoDesktop Ghostty GTK prototype runtime\n")
    ctx.file("BUILD.bazel", """load("@rules_cc//cc:defs.bzl", "cc_import", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_import(name = "native", shared_library = "lib/libaxo-ghostty-gtk.so")
cc_library(name = "bridge", deps = [":native"])
exports_files(["runtime.marker"])
filegroup(name = "runtime", srcs = glob(["lib/**", "share/**"]))
""")

ghostty_gtk_repository = repository_rule(
    implementation = _implementation,
    attrs = {
        "build_file": attr.label(default = "//linux/AxoDesktop:native/build.zig"),
        "bridge_file": attr.label(default = "//linux/AxoDesktop:native/bridge.zig"),
        "patches": attr.label_list(default = [
            "//third_party/ghostty:0001-external-terminal-io.patch",
            "//third_party/ghostty:0002-gtk-widget-bridge.patch",
            "//third_party/ghostty:0003-gtk-external-terminal.patch",
        ]),
    },
    environ = ["PATH", "HOME", "SSL_CERT_FILE", "ZIG_GLOBAL_CACHE_DIR", "PKG_CONFIG_PATH", "XDG_DATA_DIRS", "PYTHONPATH", "LD_LIBRARY_PATH"],
)
