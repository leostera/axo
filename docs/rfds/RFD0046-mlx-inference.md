# RFD0046 - Axo: embedded native MLX inference

- Feature Name: `native-mlx-inference`
- Status: Implemented (Axo 0.56)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0028](RFD0028-computer-use.md) (additional script inference backend, not a change to the judge)

## Summary

`axod-infer` binds the native MLX C++ runtime through a small owned C ABI and a thread-confined Rust binding. There is no Python, interpreter installation, repository-code execution or external MLX/Swift inference server. A killable Rust inference worker embeds MLX directly, preserving the daemon's existing crash/deadline isolation. `codemode.ai` stays host-routed and automatically resolves compatible artifacts; an optional backend selector disambiguates repositories. Implement and test MLX here serially, ship and verify it, then consider Core ML separately.

## Motivation

Axo 0.55 can inspect generic HF references but executes only GGUF. MLX-compatible safetensors models should work on Apple Silicon without asking agents to install runtimes or execute repository Python. Model format alone does not supply the architecture or task head. Initial native implementations cover dense Qwen2/Qwen3 causal generation; compatibility is architecture/configuration based, never a repository-name allowlist. Other architectures/tasks, including Clef-Omni's custom head, remain explicitly unsupported until implemented and validated.

## Guide-level explanation

Agents use HF discovery, `ai.capabilities`, `ai.info` and `ai.run` as before. GGUF selects llama.cpp; a compatible safetensors/config/tokenizer bundle selects MLX. Mixed or multiple bundles require an explicit selection rather than an arbitrary choice. An existing cached resolution retains its immutable revision. `backend: "mlx"` can request MLX explicitly; omitting it means automatic selection.

`info` inspects repository/configuration metadata without downloading weight tensors. `run` resolves, verifies downloads, initializes the selected runtime and generates text. Source receipts identify the backend, immutable revision and artifact integrity. No unsupported head is treated as generic chat.

## Reference-level explanation

### Runtime and ownership

- `third_party/mlx` pins MLX 0.32.4 and every native build dependency by SHA-256, with Python bindings and implicit CMake downloads disabled. Its Metal resource is explicit data, not a build-cache path.
- `crates/axod-infer/mlx` implements the owned C ABI. Exceptions remain on the C++ side; Rust owns returned strings and models through matching destructors. Models cannot leave their initializing worker thread or outlive the Rust runtime handle.
- The initial backend validates architecture/configuration, tensor names, dtypes and dimensions, supports ordinary floating weights and supported MLX affine quantization, and rejects extra tensors/custom heads instead of silently discarding them.
- Rust tokenization consumes verified local data with HTTP support disabled. The initial reviewed Qwen generation adapter uses the architecture's standard message framing; arbitrary tokenizer implementations or model Python are never imported.
- MLX computation runs in an Axo-owned Rust worker. The parent retains operation admission, installation and residency. A dropped async future is not native cancellation: on a runtime deadline/error, terminate and reap that worker before admitting another operation or unloading its state.
- Dropping an operation future starts independent retirement while retaining its join handle in service state. Admission waits for reaping; a failed cleanup stays unavailable until restart rather than guessing that native work stopped.
- One script operation/residency is shared between backends. Switching selections retires the prior script runtime. The computer-use judge's process, lock, socket, weights and configuration are never touched.

### Platform gates

- Rust imports and native types are under `cfg(all(target_os = "macos", target_arch = "aarch64"))`.
- Bazel native targets require macOS/arm64. Native link dependencies, generated metadata and resources use the same conditional selection; unsupported target graphs do not fetch/build MLX.
- The portable binding surface reports an unavailable backend without native imports. This is not a claim that all existing Axo subsystems already support Linux/Windows.

### Resolution and integrity

A backend-specific resolved bundle identifies its entry point, required data files and architecture/task support. Extend the GGUF-only catalog deliberately; model data paths remain relative, bounded and traversal-free. MLX selects only the required configuration, tokenizer/index and safetensors files. Missing provenance, unsupported cross-repository resources, ambiguous bundles, incompatible quantization and specialized heads produce actionable explanations before weight downloads.

Verify sizes and LFS SHA-256 digests before atomic publication. Ordinary Git metadata resources must be bound to the immutable revision's Git blob identity; compute and record their SHA-256 when obtained. Preserve published GGUF pins/cache behavior explicitly. Source schemas must distinguish a known SHA-256 from a Git-object integrity claim rather than inventing a digest.

### Limits and failure behavior

Preserve bounded input/output, model/disk admission and the 240-second operation deadline. Native tensor execution, tokenizer parsing and GPU memory are not proven safe merely because a file fits an admission budget; keep native work isolated and validate sizes/dimensions before use. Never change system-wide GPU limits or add privileged tuning. No automatic inference retries, runtime downloads, model conversions or cloud fallback. Logs contain selection/backend/task/target/outcome, not prompts or outputs.

## Validation and rollout

1. Build native MLX and test real Metal operations plus float/quantized model fixtures.
2. Exercise model ownership, errors, prediction and destruction through Rust; check platform dependency exclusion before broader integration.
3. Add one text-model vertical slice through a killable worker, with restart/deadline/switching invariants modeled before coordinating processes.
4. Add verified HF bundle inspection/installation, then the cloud schema and codemode route. Exercise distinct compatible repositories to prevent accidental name restrictions.
5. Run regression tests, package/sign the worker and Metal resource, test packaged execution away from build caches, ship, and verify live codemode behavior on the updated host.
6. Only after MLX is shipped and verified begin Core ML. No parallel implementation sessions.

Tests, not this document, are the evidence of completed behavior. An architecture candidate is not a guarantee that every checkpoint layout loads.

## Drawbacks and alternatives

- Native architecture implementations and tokenizer/head parity require maintenance; safetensors is not a universal model loader.
- The first correct generation implementation may recompute context rather than caching KV state. Report that honestly; optimize only after functional acceptance and measurement.
- MLX adds C++/Metal build work and packaged resource size. Use existing runtime primitives, not a new tensor library.
- Python is explicitly excluded. MLX-Swift is a useful source reference but a separately managed Swift service is not the selected design. Existing Rust MLX bindings were considered; the narrow owned C ABI avoids importing an independent binding/build stack for this slice.

## Unresolved questions

Exact expansion beyond the initial native architectures/tasks follows verified user needs. Core ML's generic named-feature API and Clef-Omni's native decision adapter are separate subsequent scope, not implied by this release.
