"""Builds the pinned llama.cpp `llama-server` that axod runs as its local decision side-car.

axod asks local models such as Clef "is this click destructive?" over `POST /v1/systemone` on a
Unix socket. The binary links static llama/ggml libraries without curl or OpenSSL. macOS uses
Metal with embedded shaders; Linux defaults to CPU inference, with explicit CUDA builds. Install the helper beside
axod (`Axo.app/Contents/Helpers` on macOS). CMake and Ninja come from the host.
"""

LLAMA_CPP_COMMIT = "8642541b255bfb5dc39cd351a178be09013a55d6"  # llama.cpp 0.8.0, build 11960
LLAMA_CPP_SHA256 = "1688a167a8edd9499cdd0c19b8bd044f0fa184b466981977bbf2222d884953a4"

def _accelerator_config(ctx):
    backend = ctx.getenv("AXO_LLAMA_BACKEND", "metal" if ctx.os.name == "mac os x" else "cpu")
    if backend not in ["cpu", "metal", "cuda"]:
        fail("AXO_LLAMA_BACKEND must be cpu, metal or cuda")
    if backend == "metal" and ctx.os.name != "mac os x":
        fail("Metal inference requires macOS")
    if backend == "cuda" and ctx.os.name != "linux":
        fail("Axo CUDA inference is currently supported only on Linux")
    options = [
        "-DGGML_METAL=" + ("ON" if backend == "metal" else "OFF"),
        "-DGGML_METAL_EMBED_LIBRARY=" + ("ON" if backend == "metal" else "OFF"),
        "-DGGML_CUDA=" + ("ON" if backend == "cuda" else "OFF"),
    ]
    if backend == "cuda":
        architectures = ctx.getenv("AXO_CUDA_ARCHITECTURES", "")
        if not architectures:
            fail("CUDA builds require AXO_CUDA_ARCHITECTURES (e.g. 75 for RTX 2080 Ti)")
        for arch in architectures.split(";"):
            # Explicit architecture numbers, never host-dependent 'native' or CMake expressions.
            digits = arch[:-1] if arch.endswith("a") or arch.endswith("f") else arch
            if not digits.isdigit():
                fail("AXO_CUDA_ARCHITECTURES must be semicolon-separated CUDA architecture numbers")
        toolkit = ctx.getenv("CUDA_PATH", "")
        if not toolkit or not toolkit.startswith("/"):
            fail("CUDA builds require an absolute CUDA_PATH containing bin/nvcc and static CUDA libraries")
        options += [
            "-DCUDAToolkit_ROOT=" + toolkit,
            "-DCMAKE_CUDA_COMPILER=" + toolkit + "/bin/nvcc",
            "-DCMAKE_CUDA_ARCHITECTURES=" + architectures,
            # Bundle the user-space runtime statically, not a build-host toolkit RUNPATH.
            # libcuda.so.1 still comes from the target machine's NVIDIA driver.
            "-DGGML_STATIC=ON",
            "-DCMAKE_SKIP_RPATH=ON",
        ]
    return backend, options

def _llama_server_repository_impl(ctx):
    if ctx.os.name not in ["mac os x", "linux"]:
        fail("Unsupported host for axod-infer: %s" % ctx.os.name)
    backend, accelerator_options = _accelerator_config(ctx)
    cmake = ctx.which("cmake")
    ninja = ctx.which("ninja")
    if cmake == None or ninja == None:
        fail("Building axod-infer needs cmake and ninja on PATH")
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
            "-DBUILD_SHARED_LIBS=OFF",

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
        ] + accelerator_options + (["-DCMAKE_OSX_DEPLOYMENT_TARGET=" + ctx.attr.macos_min] if ctx.os.name == "mac os x" else []),
        timeout = 600,
    )
    if configure.return_code != 0:
        fail("Configuring llama.cpp failed:\n%s\n%s" % (configure.stdout, configure.stderr))
    build = ctx.execute([str(cmake), "--build", "build", "--target", "llama-server", "--parallel", "8"], timeout = 3600)
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
        # Build capability, not a claim that a GPU is present or available at runtime.
        "compiledAccelerator": backend,
        "recognizedArchitectures": sorted(architectures),
    }))
    ctx.delete("source")
    ctx.file("BUILD.bazel", """package(default_visibility = ["//visibility:public"])

exports_files(["axod-infer", "capabilities.json"])
""")

llama_server_repository = repository_rule(
    implementation = _llama_server_repository_impl,
    attrs = {"macos_min": attr.string(default = "14.0")},
    environ = ["PATH", "AXO_LLAMA_BACKEND", "AXO_CUDA_ARCHITECTURES", "CUDA_PATH"],
)
