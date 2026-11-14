"""Native MLX, fetched only through Apple Silicon target dependencies.

No Python bindings, implicit CMake downloads, or build-cache resource paths. The native
runtime is static; its precompiled Metal library is a separately packaged data resource.
"""

MLX_VERSION = "0.32.4"
MLX_COMMIT = "36969c094354086e15d2a327a9c50feb20b9cf11"
MLX_SHA256 = "391b1e41414cddebe7a4fb5c55bf193ea5edd70e26adcfb0e1d6a5e5e86ec34a"

def _mlx_impl(ctx):
    if ctx.os.name != "mac os x" or ctx.os.arch not in ["aarch64", "arm64"]:
        fail("Native MLX needs an Apple Silicon build host; non-Apple targets must not depend on this repository")
    cmake = ctx.which("cmake")
    ninja = ctx.which("ninja")
    if cmake == None or ninja == None:
        fail("Building native MLX needs cmake and ninja on PATH")
    archives = [
        ("https://github.com/ml-explore/mlx/archive/%s.tar.gz" % MLX_COMMIT, MLX_SHA256, "source", "mlx-" + MLX_COMMIT),
        ("https://developer.apple.com/metal/cpp/files/metal-cpp_26.zip", "4df3c078b9aadcb516212e9cb03004cbc5ce9a3e9c068fa3144d021db585a3a4", "metal", "metal-cpp"),
        ("https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz", "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d", "json", "json"),
        ("https://github.com/fmtlib/fmt/archive/refs/tags/12.1.0.tar.gz", "ea7de4299689e12b6dddd392f9896f08fb0777ac7168897a244a6d6085043fea", "fmt", "fmt-12.1.0"),
    ]
    for url, sha, output, prefix in archives:
        ctx.download_and_extract(url = url, sha256 = sha, output = output, strip_prefix = prefix)
    # The upstream missing-library diagnostic reads unused NSError slots. Initialize them
    # so a missing packaged resource fails with a diagnostic, not undefined behavior.
    device = "source/mlx/backend/metal/device.cpp"
    source = ctx.read(device)
    old = "NS::Error* error[6];"
    if source.count(old) != 1:
        fail("Review the MLX missing-library diagnostic patch after updating its pin")
    ctx.file(device, source.replace(old, "NS::Error* error[6]{};"))
    result = ctx.execute([
        str(cmake), "-S", "source", "-B", "build", "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM=" + str(ninja),
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ctx.attr.macos_min,
        "-DBUILD_SHARED_LIBS=OFF",
        "-DMLX_BUILD_TESTS=OFF",
        "-DMLX_BUILD_EXAMPLES=OFF",
        "-DMLX_BUILD_BENCHMARKS=OFF",
        "-DMLX_BUILD_PYTHON_BINDINGS=OFF",
        "-DMLX_BUILD_PYTHON_STUBS=OFF",
        "-DMLX_BUILD_GGUF=OFF",
        "-DMLX_BUILD_METAL=ON",
        "-DMLX_BUILD_CUDA=OFF",
        "-DMLX_USE_CCACHE=OFF",
        "-DMLX_METAL_PATH=Resources",
        "-DFETCHCONTENT_FULLY_DISCONNECTED=ON",
        "-DFETCHCONTENT_SOURCE_DIR_METAL_CPP=" + str(ctx.path("metal")),
        "-DFETCHCONTENT_SOURCE_DIR_JSON=" + str(ctx.path("json")),
        "-DFETCHCONTENT_SOURCE_DIR_FMT=" + str(ctx.path("fmt")),
    ], timeout = 600)
    if result.return_code:
        fail("Configuring MLX failed:\n%s\n%s" % (result.stdout, result.stderr))
    result = ctx.execute([str(cmake), "--build", "build", "--target", "mlx", "--parallel", "4"], timeout = 3600)
    if result.return_code:
        fail("Building MLX failed:\n%s\n%s" % (result.stdout[-6000:], result.stderr[-6000:]))
    ctx.symlink("build/libmlx.a", "libmlx.a")
    ctx.symlink("build/mlx/backend/metal/kernels/Resources/mlx.metallib", "mlx.metallib")
    notices = []
    for name, license in [("MLX " + MLX_VERSION, "source/LICENSE"), ("metal-cpp 26", "metal/LICENSE.txt"), ("nlohmann/json 3.11.3", "json/LICENSE.MIT"), ("fmt 12.1.0", "fmt/LICENSE")]:
        notices.append(name + "\n" + ctx.read(license))
    notices.append("Hugging Face tokenizers 0.22.2\n" + ctx.read(ctx.attr.tokenizer_license))
    ctx.file("MLX-third-party-notices.txt", "\n\n".join(notices))
    ctx.file("capabilities.json", json.encode({"name": "mlx", "version": MLX_VERSION, "commit": MLX_COMMIT}))
    ctx.file("BUILD.bazel", """
load("@rules_cc//cc:defs.bzl", "cc_import", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_import(
    name = "archive",
    static_library = "libmlx.a",
    target_compatible_with = ["@platforms//os:macos", "@platforms//cpu:aarch64"],
)
cc_library(
    name = "mlx",
    hdrs = glob(["source/mlx/**/*.h"]),
    includes = ["source"],
    deps = [":archive"],
    linkopts = ["-framework", "Metal", "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "Accelerate", "-lc++"],
    target_compatible_with = ["@platforms//os:macos", "@platforms//cpu:aarch64"],
)
cc_library(name = "json", hdrs = glob(["json/single_include/**/*.hpp"]), includes = ["json/single_include"])
exports_files(["mlx.metallib", "capabilities.json", "source/LICENSE", "MLX-third-party-notices.txt"])
""")

mlx_repository = repository_rule(
    implementation = _mlx_impl,
    attrs = {
        "macos_min": attr.string(default = "14.0"),
        "tokenizer_license": attr.label(default = "//third_party/mlx:TOKENIZERS-LICENSE", allow_single_file = True),
    },
    environ = ["PATH"],
)
