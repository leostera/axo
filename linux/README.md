# Linux host (initial bring-up)

The shared Rust daemon stays in `crates/`; Linux distribution, service and desktop integration live here. This is an initial x86-64 GNU/Linux build, not a Linux desktop-app release.

## Build

Requirements: Linux 5.11 or newer with `/proc` and devpts, a C/C++ compiler, CMake, Ninja, OpenSSL development headers and pkg-config. Bazelisk selects Bazel from `.bazelversion`; Bazel selects the pinned Rust and Zig toolchains independently of the shell's Rust default.

```sh
bazel build //linux:axod //linux:runtime
```

- Daemon: `bazel-bin/crates/axod/axod`
- Runtime archive: `bazel-bin/linux/axo-linux.tar.gz`

The archive contains `axod`, the pinned `axod-infer` sidecar, and the compiled Pi extension under `AxoPi/`. Keep that layout when extracting it. Install both executables beside one another: the daemon discovers its helper relative to its own executable. Linux defaults to CPU inference; MLX and Core ML remain Apple-only.

### CUDA

Use a CUDA toolkit compatible with the host compiler and NVIDIA driver. It must include nvcc, headers, static cudart, cuBLAS/cuBLASLt and their static dependencies. Driver installation or a reboot is not part of this build. For an RTX 2080 Ti (compute capability 7.5):

```sh
bazel build //linux:runtime \
  --repo_env=AXO_LLAMA_BACKEND=cuda \
  --repo_env=AXO_CUDA_ARCHITECTURES=75 \
  --repo_env=CUDA_PATH=/absolute/path/to/cuda
```

Other explicit architecture lists use semicolons (quote the argument). `native` is deliberately rejected: build support must not silently depend on GPUs present on the builder. `AXO_LLAMA_BACKEND=cpu` explicitly selects a toolkit-free CPU artifact. macOS continues to default to embedded Metal.

CUDA user-space libraries are linked statically. The target still needs its NVIDIA driver's `libcuda.so.1`, but not the toolkit or a custom `LD_LIBRARY_PATH`. Verify the extracted helper with `ldd`, `readelf -d` and `axod-infer --list-devices`. The inference capabilities inventory reports `compiledAccelerator`; that is a build capability, not proof of GPU availability or successful offload. The existing runtime automatically places model layers; the public backend stays `llama.cpp`.

A manual service acceptance test downloads a pinned, SHA-256-verified Qwen2.5 0.5B GGUF into a separate `/tmp/axo-linux-gguf-models` cache, performs two real generations, checks reuse and retirement, and requires offload evidence for CUDA builds:

```sh
bazel test //crates/axod-infer:gguf_service_smoke_test //crates/axod-infer:gguf_cpu_smoke_test \
  --local_test_jobs=1 \
  --repo_env=AXO_LLAMA_BACKEND=cuda \
  --repo_env=AXO_CUDA_ARCHITECTURES=75 \
  --repo_env=CUDA_PATH=/absolute/path/to/cuda \
  --test_output=all
```

Use the same repository options for related builds/tests to avoid rebuilding the native helper with a different accelerator. Run `//third_party/llama.cpp:repository_test` for fast configuration checks. These are functional checks, not performance benchmarks.

## Isolated bring-up

Do not point an experimental build at a real Axo state directory. To start without production relay access:

```sh
run=$(mktemp -d)
bazel-bin/crates/axod/axod \
  --server-dir "$run/server" \
  --socket "$run/axod.sock" \
  --relay-url http://127.0.0.1:9
```

For a self-contained smoke test with a sleeping Pi fixture and no real account or user state:

```sh
python3 linux/smoke.py bazel-bin/crates/axod/axod
# After extracting the runtime archive:
python3 linux/smoke.py --bundled-resources /path/to/extracted/axod
```

This checks health RPC, session creation, terminal input/output, session close, and clean SIGTERM shutdown. It does not validate a real Pi model turn or account linking.

Logs go into the specified server directory. The daemon defaults to private file-based host credentials on Linux; it does not use or emulate Apple's Keychain.

## Boundaries

- PTY creation uses Linux grantpt/unlockpt/ptsname_r. Child descriptor inheritance uses `close_range(CLOSE_RANGE_CLOEXEC)` and fails closed if unsupported.
- Process identities include the kernel's start time; a matching PID alone is not sufficient for cleanup after daemon restarts.
- Computer use is unavailable; the existing non-macOS implementation reports that limitation.
- Privileged local IPC calls still fail closed outside macOS. A Linux tray must not bypass those checks or treat a matching Unix UID as equivalent to an Apple code signature. Linux client authorization needs a separate design before enabling question answers or other privileged app actions.
- Apple model metadata is omitted. Pairing, registration and daemon status identify Linux explicitly on the wire; some account clients may still present a macOS label. General Linux model/OS identification, browser launching, XDG model/cache paths, persistent systemd user-service installation, and Linux CI remain follow-up work.
- No tray app exists yet. Its implementation belongs under `linux/`, not `apple/`. Prefer a small StatusNotifierItem client of the daemon; GNOME needs an enabled AppIndicator/StatusNotifier host extension.

The original Apple targets remain under `apple/`. Building `//...` is not the Linux support contract: use Linux targets and the shared Rust test suites.
