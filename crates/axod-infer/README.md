# axod-infer

Local inference for axod: pinned llama.cpp for GGUF and embedded native MLX for compatible
safetensors bundles on Apple Silicon. The native MLX C++ runtime is bound through an owned C
ABI and thread-confined Rust types, running in Axo's killable Rust worker—not Python or a
third-party inference server. Both helpers and Metal resources ship with the signed app.
The computer-use gate keeps its separate Clef runtime; script backends share one residency
in `run/ai/`. Neither script backend can unload or reconfigure the safety judge.

## Discover → inspect → run

There is **no model-name allowlist**. Runtime support, available artifacts and the task matter.
Discovery belongs to the account's Hugging Face connection, not a second search engine in Axo:

```js
const host = "mac_studio";
const capabilities = await codemode.ai.capabilities({ host });
// capabilities.runtime.recognizedArchitectures is generated from the exact llama.cpp pin.
// formats/tasks/modalities and resource limits describe this host, not a fixed catalog.

const candidates = await codemode.hugging_face.hub_repo_search({
  query: "Clef", repo_types: ["model"], filters: ["gguf"]
});
const model = "hf:ggml-org/Clef-Flash-GGUF:Q4_K_M";
const { info } = await codemode.ai.info({ host, model });
if (info.compatibility.status !== "candidate") return info.compatibility;

return codemode.ai.run({
  host, model, task: "classify",
  input: {
    state: { task: "Review this image" },
    images: [attachment], // {asset,name,mimeType,size}, e.g. a screenshot's attachment
    questions: {
      portrait: { type: "noul", instructions: "Does this image contain a portrait?" },
      kind: { type: "choice", instructions: "What is depicted?",
        criteria: { person: "A person", landscape: "An outdoor landscape", other: "Something else" } }
    }
  }
});
```

`info` fetches metadata, not model weights. Its compatibility is `candidate`, `unsupported`
or `ambiguous`, with reasons. A recognized architecture is not proof that every tensor layout,
quantization, projector or decision head works: **the pinned runtime makes the final load test**.
The architecture inventory is extracted at build time from that runtime's `LLM_ARCH_NAMES`,
excluding dummy/unknown entries; it is not a manually maintained supported-model list.

Native MLX initially implements **dense Qwen2/Qwen3 text generation**, with supported uniform
affine quantization (2/4/8 bits, groups 32/64/128), standard Qwen message framing, a 4096-token
context and no KV cache. These are architecture implementations, not allowed repository names.
`capabilities.runtimes` reports the exact MLX pin, a real packaged-resource/device probe, and
backend-specific tasks/limits. Recognition still does not guarantee every checkpoint loads.

```js
await codemode.ai.run({
  model: "hf:mlx-community/Qwen3-0.6B-4bit",
  input: "Write a short greeting.", host: "mac_studio",
}); // automatically selects native MLX
// Add backend: "mlx" to disambiguate a repository with multiple formats.
```

`hf:mlx-community/clef-omni-4bit` remains a valid but unsupported reference: its backbone and
custom joint decision head are not implemented by this adapter. Generic generation is not a
classifier substitute. Vision, MLX embeddings, custom heads and Core ML remain separate work.
There is no Python, repository-code import, dependency installer or automatic conversion.

## API

Every method takes `host` (a paired online Mac's name; default `self`).

| Method | Purpose |
| --- | --- |
| `capabilities({host})` | Actual backend pin, recognized architectures, adapter tasks/modalities and resource limits. No network or model load. |
| `info({host,model,backend?,file?,projector?})` | Inspect pinned HF configuration/index metadata; resolve compatible GGUF or MLX data bundles, or explain why not. |
| `list({host})` | Inventory of managed selections, partial/complete installation and residency. Not a list of allowed models. |
| `install({host,model,file?,projector?})` | Optional prefetch. `run`/`load` install automatically. |
| `load({host,model,task?,file?,projector?})` | Optional prewarm; default task is `generate`. |
| `unload({host,model,file?,projector?})` | Stop only this exact script-managed selection; retain files. |
| `run({host,model,task,input,...})` | Resolve, install, load and execute the selected task. |

References are `hf:owner/repo[:quant][@revision]`. Without an explicit artifact, selection
prefers Q4_K_M, Q8_0, Q4_0, F16, BF16, then other variants, and requires a unique choice at the
best rank. A `:quant` selector matches quantization tokens in artifact names, not a model allowlist.
`file` selects the first model shard in a bundle. Every weight shard needs metadata
with its size and SHA-256. A unique projector, or unique Q8_0 projector, is selected automatically;
otherwise specify `projector`. Projectors and `:quant` selectors apply only to GGUF. MLX
quantization comes from verified bundle configuration; no model conversion is attempted.
`backend` is optional (`llama.cpp` or `mlx`); mixed formats or multiple bundles require an
explicit, unambiguous choice. Selectors never accept local paths, traversal or URLs.

The first install pins the resolved HF commit and exact artifacts in a local manifest. Later
calls reuse that pin, including interrupted downloads. Use `@<commit>` for explicit provenance
or another revision/selection to select another version. `source` receipts identify the repo,
commit, primary file/SHA-256 and all model/projector shards.

### Task adapters

```js
// Text or multimodal generation. maxTokens defaults to 512 (maximum 4096).
await codemode.ai.run({ model, task: "generate", input: { text: "Describe this image", images: [attachment] }, maxTokens: 128 });
// Plain strings are also accepted for text. 0.54's prompt spelling remains generate-only.
await codemode.ai.run({ model, input: "Write a greeting" });

// Native decision models through /v1/systemone, not prompt-based chat masquerading as a classifier.
await codemode.ai.run({ model, task: "classify", input: { state, images: [attachment], questions } });
// Question types: noul (yes/no probability), choice (named criteria), score (2–10 ordered descriptions).

// Dedicated text embedding models, started with --embeddings.
await codemode.ai.run({ model: "hf:ggml-org/embeddinggemma-300M-GGUF:Q8_0", task: "embed", input: "Text to retrieve" });
```

Generation returns `{model,task,text,finishReason,source}`; `length` means the output hit its
limit. Classification returns `{model,task,answers,source}` with validated probabilities.
Embedding returns `{model,task,embedding,source}` with finite vector values. Task hints from
HF metadata are advisory, not proof that the adapter can run a repository's custom head.

Images are PNG/JPEG/WebP account attachments or small base64 data URLs. The daemon fetches
attachments using its account credential, verifies them and turns the bytes into runtime inputs.
Filesystem paths and arbitrary remote image URLs are not accepted. For large images, use assets,
not inline bytes in a script or relay request. Audio/video inputs are not exposed yet.

## Lifecycle, limits and trust

- One AI operation and one script-managed model/task residency per daemon. A different selection
  or task retires the previous process. Busy is returned instead of an unbounded queue; unload
  cannot interrupt an active request. The safety judge is independent.
- Transfers go directly from HF to the target Mac. Weights resume into `.part`, are size/SHA-256
  verified and atomically published. Ordinary Git config/index resources are pinned to Git-object
  integrity; their computed SHA-256s are recorded in completed manifests/receipts too. A
  cross-process lock covers transfer, verification and publication.
  Manifests live under `~/Library/Application Support/Axo/models/hf/`.
- Guarded launches map the lifeline and lock through standard I/O and use `posix_spawn`, avoiding
  the macOS `fork`/notification-initialization race. curl is the guard's direct child. A dropped
  transfer future stops its guard; an interrupted transfer resumes on a later call.
- Installed helper/resources required. MLX's Rust worker watches its owner's stdin lifeline,
  retains the process lock on stdout, and is killed/reaped before native ownership is released.
  No pre-exec callbacks or shell descendants are needed for native MLX cancellation.
- Weights/projectors/resources are admitted up to 60% of physical RAM, with
  at most 64 GiB/128 artifacts per selection. Installation needs space for missing artifacts
  plus a 512 MiB reserve. These are admission budgets, not a guarantee of peak runtime memory.
- Four images maximum, 8 MiB each/16 MiB combined; text/state up to 32768 UTF-8 bytes;
  16 typed questions. Relay requests fit 64 KiB, so use attachment references. The runtime
  context is 8192 tokens for llama.cpp and at most 4096 for the initial MLX adapter; a request
  within the byte limit can still exceed a model's context.
- Each operation has at most 240 seconds, bounded by the script's remaining five minutes.
  A runtime timeout retires the process; metadata/input failures do not stop an unrelated
  resident model. Disconnecting a caller is not a cancellation receipt: its job may run until
  its deadline. There are no automatic inference retries or cloud fallbacks.
- Public ungated HF repositories only. License/gating requirements are not silently accepted,
  and the HF discovery MCP grant is not assumed to be a download token. Model terms still apply.
- Only supported model data is downloaded: GGUF or verified MLX config/tokenizer/index/safetensors
  bundles. No `trust_remote_code`, repository Python, arbitrary executables,
  runtime CLI flags, third-party runtime installers or model-invoked tools are exposed.
- Model inference is local, but requests/results traverse the account's cloud script/relay.
  AI call logs contain selection/task/target/outcome, not text, state, questions, images or outputs.
  The agent's own Session transcript can still contain what it passes/returns.

## Build and test

```sh
bazel test //crates/axod-infer:axod_infer_tests //crates/axod-infer:mlx_binding_tests //crates/axod-infer/mlx:native_test
# Explicit opt-in: real HF installation, generation, deadline, restart and residency.
bazel test //crates/axod-infer:mlx_service_smoke_test --test_output=all
bazel test //packages/axo-api:test //packages/axo-api-worker:test //packages/axo-api-worker:relay_test
```

The opt-in real-model test exercises HF inspection, **two distinct generation models**, and
optional real embedding/classification models through an isolated Worker/account/daemon. It
can additionally execute native MLX Qwen2/Qwen3 selections and switch backends without unloading
between calls. Unsupported specialized heads still get an actionable explanation. The classifier test saves an image
asset and passes its attachment through `ai.run`. It does not deploy production code.

```sh
bazel build @llama_server//:axod-infer
bazel test //packages/axo-api-worker:ai_smoke_test \
  --test_env=AXO_TEST_AI_HELPER="$(bazel info output_base)/external/+llama_server_repository+llama_server/axod-infer" \
  --test_env=AXO_TEST_AI_MLX_HELPER="$PWD/bazel-bin/crates/axod-infer/axod-infer-mlx" \
  --test_env=AXO_TEST_AI_MLX_METALLIB="$PWD/bazel-axo/external/+mlx_repository+mlx/mlx.metallib" \
  --test_env=AXO_TEST_AI_EMBEDDING=hf:ggml-org/embeddinggemma-300M-GGUF:Q8_0 \
  --test_env=AXO_TEST_AI_CLASSIFIER=hf:ggml-org/Clef-Flash-GGUF:Q4_K_M \
  --test_output=all
```

Weights use a persistent `/tmp/axo-general-ai-models` cache (`AXO_TEST_AI_CACHE` overrides it).
`AXO_TEST_AI_SEED_DIRS` is a JSON array of existing weight directories; matching files are
SHA-256 checked against HF metadata and copied copy-on-write where supported. This avoids
redownloading the safety judge's already-installed Clef weights. `AXO_TEST_AI_MODELS` can
supply a JSON array of alternate generation requests. These controls are test-only.
