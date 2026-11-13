# axod-infer

Local inference for axod: running models on this Mac in a side-car. The first model is Clef, asked typed questions about a state over llama.cpp's `POST /v1/systemone` on a Unix socket, returning a probability for every option.

- The side-car is `axod-infer`, the pinned `llama-server` build in `Axo.app/Contents/Helpers`, so a crash in Metal or the model cannot take axod down.
- axod starts it on the first question, as its child under the lifeline (`Lifeline::guarded`), so it ends with axod however axod ends. It holds an exclusive lock on `infer.lock` for as long as it lives: never more than one, and a crashed one is started again on the next question. One that axod did not start (an earlier axod's) is found through its socket's peer, killed and replaced. The model download runs the same way.
- It unloads the model after ten idle minutes and loads it again on demand.
- `Infer::beside_current_exe` finds the side-car; `installed` says whether it and the model files (`MODEL_FILE`, `VISION_FILE`) are on disk; `install_in_background` downloads them, unless this Mac lacks the memory or disk; `ask` sends one `systemone` request.

## Script-managed Gemma (`codemode.ai`)

The daemon's inference service (`src/service.rs`) owns a separate side-car in `run/ai/`.
It never unloads or configures the computer-use judge. The first supported model is
[`hf:ggml-org/gemma-3-270m-it-GGUF`](https://huggingface.co/ggml-org/gemma-3-270m-it-GGUF),
instruction-tuned Q8_0. The reviewed HF revision and SHA-256 are pinned in the source.
This is not an arbitrary Hugging Face model loader.

From an account codemode script:

```js
const model = "hf:ggml-org/gemma-3-270m-it-GGUF";
await codemode.ai.list({}); // host defaults to "self"; does not install/load
const result = await codemode.ai.run({ model, prompt: "Write a short greeting.", maxTokens: 64 });
return result; // { model, text, finishReason, source: { repo, revision, file, sha256 } }
```

- `run` automatically installs the 291,545,600-byte artifact, loads it and generates.
  `install` optionally prefetches without loading; `load` optionally prewarms.
  `unload` stops only this service's model and keeps downloaded files.
- Every operation accepts `host`, a paired online Mac's name or `self`.
  Files go directly from HF onto that Mac, not through the cloud script or MCP results.
  Public downloads do not require the Hugging Face discovery MCP connection.
- Downloads resume into `.part`; the exact size and SHA-256 are verified before atomic
  publication. A cross-process download lock covers transfer and verification.
  curl is the lifeline guard's direct child, so axod exit or cancellation stops the transfer.
- A Mac needs at least 4 GiB of RAM and 1 GiB free for installation. This service admits
  one operation at a time and returns busy rather than building an unbounded queue.
  The process follows axod's lifeline, sleeps after 10 idle minutes, and restarts on demand.
- Each cloud-routed operation gets at most 240 seconds, capped by the script's remaining
  five-minute budget. A timed-out request retires the script model process. A caller that
  stops waiting or loses its relay connection may leave a job running until its deadline:
  calls are never automatically retried. An interrupted transfer resumes on another call.
- Generation accepts 1–32768 UTF-8 prompt bytes and 1–4096 output tokens (512 by default).
  The runtime context is 8192 tokens; a prompt within the byte limit can still exceed it.
  `finishReason: "length"` means output was cut off at the token limit. This tiny model is
  not a reliable reasoning model; a smoke test is not an accuracy guarantee.
- Prompts/results traverse the account's cloud sandbox and relay. The AI call log stores
  only host/model/operation and outcome, not prompts, generated text or model error bodies.
  A Session's own transcript may still contain what an agent passes to or returns from a script.
- Generation is text-only. Images, embeddings, other model refs, gated/private repos,
  arbitrary URLs, runtime flags, cloud fallbacks and repository-code execution are not exposed.
  Model terms still apply: see [Gemma terms](https://ai.google.dev/gemma/terms).
  Clairic is deferred until official weights and compatible runtime support can be verified.

## Build and test

```sh
bazel build //crates/axod-infer
bazel test //crates/axod-infer:axod_infer_tests
```
