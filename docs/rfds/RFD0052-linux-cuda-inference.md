# RFD0052 - Axo: Linux CUDA inference

- Feature Name: `linux-cuda-inference`
- Status: Implemented (experimental Linux runtime)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0046](RFD0046-mlx-inference.md) (additional llama.cpp build capability, not a new model backend)

## Summary

Build the pinned llama.cpp helper with explicitly selected CUDA support on Linux. Keep the existing inference protocol, verified GGUF installation, task adapters, admission, lifeline and retirement behavior. CPU remains the default Linux build; macOS keeps embedded Metal. Implement and validate CUDA first, then Linux computer use, serially.

## Motivation

starbase2's RTX 2080 Ti supports CUDA compute capability 7.5, but the initial Linux runtime only uses CPU inference. GPU acceleration should reuse the same reviewed model loader and process isolation rather than introducing a second service or executing model repository code.

## Guide-level explanation

A builder selects `AXO_LLAMA_BACKEND=cuda`, an explicit semicolon-separated `AXO_CUDA_ARCHITECTURES` list and an absolute `CUDA_PATH` through Bazel's `--repo_env`. For starbase2 the architecture is `75`. No GPU discovery changes build outputs implicitly. `linux/README.md` documents the complete command.

The resulting archive has the existing `axod`, `axod-infer`, `AxoPi/` layout. `ai.capabilities` reports `compiledAccelerator` in the llama.cpp inventory: `cpu`, `metal` or `cuda`. This describes the artifact, not present hardware, free VRAM or a successful model load. The public backend remains `llama.cpp`; CUDA is not a model format or a new backend selector.

CPU-only builds do not require a CUDA toolkit or driver. CUDA artifacts link CUDA's user-space runtime and BLAS statically and require the target's NVIDIA driver (`libcuda.so.1`). They are not advertised as portable to machines without that driver. A CUDA-enabled helper can still execute on CPU on a driver-equipped machine with zero GPU layers; automatic placement remains the pinned runtime's existing policy.

## Reference-level explanation

`third_party/llama.cpp/repository.bzl` validates the platform/backend combination before downloading sources. It explicitly sets `GGML_CUDA` and Metal flags, requires stable architecture numbers for CUDA, points CMake at the requested toolkit, enables static CUDA linkage and omits toolkit RUNPATHs. The four relevant environment inputs are tracked by the repository rule. Unknown backends and unsupported platform combinations fail rather than silently producing CPU builds.

Do not change driver packages, network configuration, kernel modules or system-wide tuning as part of enabling this capability. The experimental toolkit on starbase2 is installed under the user's home from NVIDIA redistributable archives with SHA-256 verification. Toolchain provenance and observed validation belong in the private research record, not credentials or machine state in Git.

### Invariants

- Preserve the pinned llama.cpp commit and source archive digest, disabled curl/OpenSSL and repository-code execution policy.
- Preserve verified immutable model sources, task validation, operation deadlines, single-operation admission, private sockets, descriptor inheritance and child retirement.
- Do not alter the separate decision judge's weights, socket or residency during script inference validation.
- The artifact must execute after extraction with `LD_LIBRARY_PATH` unset; no dependency on the build-cache or toolkit location is allowed at runtime.
- Existing Metal builds and CPU-only Linux builds remain explicit alternatives, not runtime compatibility shims.
- No active paired daemon restart or production publication is required for acceptance testing.

## Rollout and validation

1. Test default and explicit CPU, embedded Metal, explicit CUDA flags and rejected configuration boundaries without compiling native dependencies.
2. Build and extract the CUDA runtime. Inspect dynamic dependencies and RUNPATHs; enumerate the real GPU with the packaged helper.
3. Run the manual `gguf_service_smoke_test` against immutable public GGUF weights. Verify artifact integrity receipts, nonempty generations, resident worker reuse, actual CUDA layer-offload logs and worker retirement.
4. Exercise CPU execution independently, run inference regression tests and the extracted daemon smoke. Keep performance claims separate from functional evidence.
5. Record exact results before beginning Linux computer-use implementation. Installing/restarting the paired runtime is a separate rollout action, not an implication of a passing isolated test.

## Validation evidence

On starbase2 (Ubuntu 26.04.1, GCC 15.2, NVIDIA driver 595.99.02), the rootless CUDA 13.2.51 toolkit built the pinned helper for architecture 75. The extracted helper enumerated the RTX 2080 Ti with `LD_LIBRARY_PATH` unset. `ldd` showed only the system NVIDIA driver and ordinary system libraries; `readelf -d` showed no RUNPATH/RPATH.

Seven configuration tests passed on Linux and macOS; 26 inference unit tests passed on Linux. Both real GGUF acceptance suites passed: automatic CUDA placement offloaded 25 layers; forced CPU placement offloaded zero and loaded a CPU model buffer. Each performed two generations with verified immutable weights, reused the worker, then unloaded and verified its process exited. The default log threshold did not include the offload inventory, so only the fixed-prompt acceptance targets enable trace logging. Production logging is unchanged.

The rebuilt extracted CUDA archive passed health RPC, session creation, PTY input/output, session close and clean SIGTERM shutdown with an isolated HOME and fixture. The paired daemon remained active and was not replaced or restarted. macOS configuration was tested; the full native Metal build/regression suite was not rerun for this change. No performance comparison is claimed.

## Drawbacks and alternatives

- CUDA builds are larger and require compatible NVIDIA toolchains and target drivers. Static BLAS avoids bundling a shared-library tree but increases the helper size.
- Explicit architecture selection adds configuration; selecting `native` would be simpler but makes cache identity and artifact support depend on GPUs present while building.
- Dynamic CUDA linkage could shrink the executable, but the current archive has no audited CUDA library bundler. Depending on an arbitrary toolkit RUNPATH is not an acceptable substitute.
- Vulkan, HIP and a separate inference engine remain future possibilities. CPU-only execution remains the simplest alternative but leaves the installed GPU unused.

## Unresolved questions

Broader architecture lists, distributed CUDA artifacts, toolkit hermeticity and performance tuning are later work. They do not change this first host's functional acceptance criteria.
