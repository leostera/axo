# RFD0047 - Axo: native Core ML predictions

- Feature Name: `native-coreml-inference`
- Status: Implemented (release verification pending)
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0046](RFD0046-mlx-inference.md) (another embedded native backend after MLX shipped)

## Summary

Extend the existing host-routed `codemode.ai` pipeline with a macOS Core ML backend, embedded through a small Objective-C++/C ABI and thread-confined Rust binding. Keep downloads, admission and kill/reap ownership in Axo, reuse the MLX worker containment mechanism, and expose Core ML's named inputs/outputs through a new `predict` task rather than pretending every graph is a chat or decision model. Implement serially in this Session, validate the entire pipeline, then publish the next Axo after 0.56.

## Motivation and scope

MLX shipped in 0.56. Apple-native Core ML models need their native framework, source model/package loading and explicit feature bindings. The first useful scope is bounded scalar/tensor prediction and image inputs, including ordinary neural networks and reviewed built-in ML Programs. Core ML text generation, mutable model state, training, custom classes/layers/operators, linked models, arbitrary compiled binaries and automatic conversion are not included.

A tiny arithmetic model proves the native binding and error/ownership behavior without downloads. A real public image model, such as `apple/coreml-FastViT-T8`, proves that packaged ML Programs and verified images work, not just a toy legacy regressor. These are tests, not a production model-name allowlist.

## Guide-level explanation

The existing discovery → capabilities → info → run flow stays intact. Compatible `.mlmodel` or `.mlpackage` artifacts select Core ML automatically when unambiguous; `backend: "coreml"` resolves mixed-format repositories. Metadata inspection does not download weight tensors or compile a graph. Compilation and full graph/feature checks happen after verified installation.

`ai.load({model, task: "predict"})` can return the native feature description. `ai.run` takes `task: "predict"` and `input: {features: {featureName: typedValue}, outputs?: [selectedNames]}`, returning `{model, task, outputs, source}`. Output projection selects complete named features; it does not silently truncate or normalize them. Typed values distinguish scalar strings/numbers, numeric tensors and image inputs. Images use the existing verified account attachment/data-URL boundary; no arbitrary paths or image URLs.

Native fixed-label classification is not the schema-conditioned `classify` task. Likewise, numeric feature prediction does not imply an embedding tokenizer or an autoregressive generation adapter. Capabilities and errors must explain those distinctions.

## Reference-level explanation

### Native ownership and platform gates

- Link the system Core ML framework through a narrow Objective-C++ C ABI. No Python, runtime installer, third-party server or repository-code import.
- Keep model handles thread-confined and predict through exclusive mutable access. Translate C++, Objective-C and framework errors at the ABI boundary; use matching allocation/destruction functions.
- Gate Rust imports/types and Bazel native dependencies on macOS, independently of MLX's additional Apple Silicon requirement. Linux/Windows must not build Apple frameworks.
- Generalize only the existing process containment mechanism needed by both native workers: owner lifeline, private socket/directory, retained lock, bounded requests, idle exit, deadline kill/reap and cancellation-safe retirement. The safety judge remains independent.
- Put source snapshots and retained compiled assets under an explicitly passed private worker workspace. Keep assets alive for lazy reads; the parent removes the workspace only after kill/reap, including hard termination. Apple's compiler API can also create framework-owned temporary files/caches outside that directory; do not claim those are all controlled by Axo. Do not ship or accept arbitrary downloaded `.mlmodelc` executables as source models.

### Trust boundary

Inspect source specifications before native compilation. Reject custom model/layer/operator hooks, linked models and unsupported nested/control-flow graphs. Built-in ML Program operations require a reviewed supported operation set; unknown operations are unsupported, not automatically registered.

Validate all external blob references and package-manifest paths against the verified local bundle. No traversal, absolute paths, symlinks, secondary repositories, URLs or reads outside the snapshot. Bound protobuf/JSON sizes, field counts, nesting, shapes and allocations. Native compilation remains isolated even after these checks; format verification is not a claim that Apple's parser cannot fail.

The initial MLX prototype's Core ML bridge is review material only. Its legacy-only graph verifier and limited feature implementation do not establish ML Program support or readiness to ship.

### Catalog and public contract

Resolve one explicit model/package entry point and all required data resources at one immutable HF revision. Extend the existing manifest type deliberately, preserving GGUF/MLX cache keys and revision pins. Ordinary Git model/spec resources may initially have Git-object integrity rather than an advertised SHA-256; record computed SHA-256s on successful installation as in 0.56.

Source receipts must never invent a digest. Keep old inference API 2/3 GGUF/MLX receipts accepted at the Worker boundary; new Core ML/predict requests to older hosts need an update instruction. Bump the host inference API for the new task/backend. Keep prompts/features/images/results out of AI call logs.

Use Core ML's actual feature descriptions to validate names, required inputs, dtypes and dimensions. Enforce aggregate element/string/image budgets before inference, then validate finite, bounded native outputs. Report available native compute devices and the configured compute policy; do not promise Neural Engine execution for every model.

## Validation and rollout

1. Native GLM fixture: compile/load/describe/predict, wrong names/shapes/dtypes, nonfinite values, cleanup and rejected custom graphs. Generate fixtures natively; no Python toolchain.
2. Native built-in ML Program and package/blob-path tests, including rejection of custom or escaping references.
3. Generic typed prediction boundary, verified HF package installation, worker lifecycle and platform-gating tests. Preserve MLX/GGUF regression behavior.
4. Small Session-scoped `codemode.ai` tests: capabilities, metadata info, load/describe, predict, reuse/unload and failure behavior through Worker → relay → daemon → native Core ML. Exercise a real public model, not only a direct framework call.
5. Run all regression tests, sign/package the worker, download the published artifact and rerun the end-to-end tests away from the build tree. Publish only the tasks/features that passed. Do not restart the person's active Axo Session merely to claim a live-host test.

## Drawbacks and alternatives

- Raw feature prediction is lower-level than chat; task-specific tokenization/generation adapters remain explicit future work.
- Graph verification and Core ML OS/operator differences need maintenance and negative tests. A file extension is not proof of compatible or safe behavior.
- Legacy-only support is simpler but excludes common ML Programs; do not call that broad package support.
- Converting models, importing HF Python or creating another inference service would violate the selected native-loading boundary.

## Sources and open implementation questions

- Apple's Core ML source schema reference was inspected at coremltools commit `a207b1a3452eafe02f2d870f486287834af2c82d`: [MIL.proto](https://github.com/apple/coremltools/blob/a207b1a3452eafe02f2d870f486287834af2c82d/mlmodel/format/MIL.proto), [Model.proto](https://github.com/apple/coremltools/blob/a207b1a3452eafe02f2d870f486287834af2c82d/mlmodel/format/Model.proto), [NeuralNetwork.proto](https://github.com/apple/coremltools/blob/a207b1a3452eafe02f2d870f486287834af2c82d/mlmodel/format/NeuralNetwork.proto). These are format references, not runtime dependencies or a completed security review.
- [Apple's FastViT-T8 Core ML package](https://huggingface.co/apple/coreml-FastViT-T8/tree/b42811edaa9f7ca6d79eeada204227704484c881) passed native and codemode image prediction. Its 1000-logit head repeats the label `crane`, so the native string-key probability dictionary has 999 entries. Full dictionary replies varied around/exceeded the relay limit; explicit named-output projection is tested.
- The reviewed built-in operation set is explicit in `coreml/spec.h`; unknown operations fail closed. First public tensors are float32/int32, ranks 1..16, at most 4096 aggregate elements per direction and 32 feature bindings. Scalars are finite numbers, exact JavaScript integers or bounded UTF-8 strings. Image inputs are bounded PNG/JPEG/WebP, decoded to fixed BGRA8/grayscale8 constraints with scale-fill semantics. Core ML compiler/device compatibility is finally determined on the target OS.

## Implementation evidence

- Native arithmetic fixtures compile and run directly: a legacy GLM returns 24, and a flat ML Program maps `[4,5]` to `[8,10]`. Negative tests reject custom/linked/serialized models, nested custom layers, unsafe operations, state, control flow, traversal/external blob paths, malformed protobuf and oversized/static tensor dimensions.
- The actual framework/device probe reports CPU, GPU and Neural Engine on this Apple Silicon Mac, without claiming which device executes a model. Framework-owned compilation is isolated in the Axo worker. The C ABI normalizes the private manifest before compilation so JSON duplicate-key interpretation cannot bypass inspected paths.
- Shared native transport and parent containment preserve owner stdin lifelines, inherited stdout locks, deadlines, kill/reap and retirement ownership. Core ML process tests cover selected-image prediction, error recovery, stale-workspace cleanup, stop and Drop reaping. Real MLX lifecycle smoke still passes after the refactor.
- Real Core ML service smoke verifies HF inspection, pinned package integrity, installation, feature descriptions, reuse, selected outputs, native rejection, retirement cleanup, reload and unload.
- The seven-model isolated Session/account integration executes actual `codemode.ai` calls through cloud Worker → authenticated relay → daemon → native backend. It tests two GGUF generators, two MLX generators, FastViT prediction with a verified account image attachment, GGUF embeddings and native typed classification, including backend switches and unload.
- All 77 standard Bazel tests pass; signed bundle tests verify the Core ML helper, signing identifier/team, minimum OS and real device probe. Published-artifact verification remains a release gate, not yet recorded here.
- The full Core ML worker successfully cross-compiles for Intel macOS. Crate-universe now preserves its default targets and additionally supports `x86_64-apple-darwin`; dependency versions are unchanged. This Mac's runtime tests execute on Apple Silicon, not Intel hardware.
- Linux/Windows native dependencies are Rust/Bazel-gated out. Full Linux Bazel analysis is still blocked by the missing cross C++ allocator toolchain, as before; do not report a successful full cross-platform build. The bounded lifecycle specification passes its three properties over 41 explored states; source locking remains subject to the existing unrelated relay-spec validation failure.
- The full suite exposed a pre-existing Cloudflare Vite build issue: the plugin rewrote Bazel-owned read-only declarations. Build mode now leaves generation to `cf types`; dev mode retains automatic generation. The full suite passed after that fix and the inference API 4 assertion update.
