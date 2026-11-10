# axod-infer

Local inference for axod: running models on this Mac in a side-car. The first model is Clef, asked typed questions about a state over llama.cpp's `POST /v1/systemone` on a Unix socket, returning a probability for every option.

- The side-car is `axod-infer`, the pinned `llama-server` build in `Axo.app/Contents/Helpers`, so a crash in Metal or the model cannot take axod down.
- axod starts it on the first question, as its child under the lifeline (`Lifeline::guarded`), so it ends with axod however axod ends. It holds an exclusive lock on `infer.lock` for as long as it lives: never more than one, and a crashed one is started again on the next question. One that axod did not start (an earlier axod's) is found through its socket's peer, killed and replaced. The model download runs the same way.
- It unloads the model after ten idle minutes and loads it again on demand.
- `Infer::beside_current_exe` finds the side-car; `installed` says whether it and the model files (`MODEL_FILE`, `VISION_FILE`) are on disk; `install_in_background` downloads them, unless this Mac lacks the memory or disk; `ask` sends one `systemone` request.

## Build and test

```sh
bazel build //crates/axod-infer
bazel test //crates/axod-infer:axod_infer_tests
```
