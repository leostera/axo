"""Builds the pinned llama.cpp `llama-server` that axod runs as its local decision side-car.

axod asks local models such as Clef "is this click destructive?" over `POST /v1/systemone` on a
Unix socket. The binary is static, uses Metal with its shaders embedded, and has no curl or
OpenSSL, so it links only system frameworks and ships as `Axo.app/Contents/Helpers/axod-infer`.
llama.cpp publishes no macOS binaries, so it is built here; CMake and Ninja come from the host.
"""

LLAMA_CPP_COMMIT = "8642541b255bfb5dc39cd351a178be09013a55d6"  # llama.cpp 0.8.0, build 11960
LLAMA_CPP_SHA256 = "1688a167a8edd9499cdd0c19b8bd044f0fa184b466981977bbf2222d884953a4"

def _llama_server_repository_impl(ctx):
    if ctx.os.name != "mac os x":
        fail("axod-infer is built for macOS hosts only")
    cmake = ctx.which("cmake")
    ninja = ctx.which("ninja")
    if cmake == None or ninja == None:
        fail("Building axod-infer needs cmake and ninja on PATH (brew install cmake ninja)")
    ctx.download_and_extract(
        url = "https://github.com/ggml-org/llama.cpp/archive/%s.tar.gz" % LLAMA_CPP_COMMIT,
        sha256 = LLAMA_CPP_SHA256,
        strip_prefix = "llama.cpp-" + LLAMA_CPP_COMMIT,
        output = "source",
    )
    configure = ctx.execute(
        [
            str(cmake),
            "-S",
            "source",
            "-B",
            "build",
            "-G",
            "Ninja",
            "-DCMAKE_MAKE_PROGRAM=" + str(ninja),
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ctx.attr.macos_min,
            "-DBUILD_SHARED_LIBS=OFF",
            "-DGGML_METAL=ON",
            "-DGGML_METAL_EMBED_LIBRARY=ON",
            "-DGGML_NATIVE=OFF",
            # Bazel owns caching. Host sccache cannot reliably cache generated Metal assembly.
            "-DGGML_CCACHE=OFF",
            "-DLLAMA_CURL=OFF",
            "-DLLAMA_OPENSSL=OFF",
            "-DLLAMA_BUILD_TESTS=OFF",
            "-DLLAMA_BUILD_EXAMPLES=OFF",
            "-DLLAMA_BUILD_SERVER=ON",
            "-DLLAMA_BUILD_TOOLS=ON",
            # The version llama-server reports, without a git checkout to read it from.
            "-DLLAMA_BUILD_COMMIT=" + LLAMA_CPP_COMMIT[:9],
            "-DLLAMA_BUILD_NUMBER=11960",
        ],
        timeout = 600,
    )
    if configure.return_code != 0:
        fail("Configuring llama.cpp failed:\n%s\n%s" % (configure.stdout, configure.stderr))
    build = ctx.execute([str(cmake), "--build", "build", "--target", "llama-server"], timeout = 3600)
    if build.return_code != 0:
        fail("Building llama-server failed:\n%s\n%s" % (build.stdout[-4000:], build.stderr[-4000:]))
    ctx.symlink("build/bin/llama-server", "axod-infer")
    # Derive recognition from this exact runtime pin, not a hand-maintained model allowlist.
    architecture_map = ctx.read("source/src/llama-arch.cpp").split("LLM_ARCH_NAMES = {", 1)[1].split("};", 1)[0]
    architectures = []
    for line in architecture_map.split("\n"):
        if "\"" in line:
            name = line.split("\"")[1]
            if name not in ["clip", "(unknown)"]:
                architectures.append(name)
    if len(architectures) < 20:
        fail("Could not extract llama.cpp's architecture inventory; review the pinned source format")
    ctx.file("capabilities.json", json.encode({
        "name": "llama.cpp",
        "commit": LLAMA_CPP_COMMIT,
        "build": 11960,
        "recognizedArchitectures": sorted(architectures),
    }))
    ctx.delete("source")
    ctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["axod-infer", "capabilities.json"])
""")

llama_server_repository = repository_rule(
    implementation = _llama_server_repository_impl,
    attrs = {"macos_min": attr.string(default = "14.0")},
    environ = ["PATH"],
)
