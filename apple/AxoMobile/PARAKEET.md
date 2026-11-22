# English on-device dictation

Axo uses NVIDIA **Parakeet TDT 0.6B v2** for live iPhone/iPad dictation and for
Watch recordings transcribed on the paired iPhone. The microphone button prepares the model
before recording. Live text is tentative; Stop saves a draft and only explicit Send can send.
At 90 seconds live recording stops into a draft. Watch Send uses the existing paired transfer;
if the model is missing the Watch asks you to finish setup on iPhone and nothing is sent.
Neither path uploads audio or falls back to another recognizer.

## Artifacts and attribution

- NVIDIA [parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/tree/c00e38779b028d48624b08ab3d9909952db43901),
  [.nemo SHA-256](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/blob/c00e38779b028d48624b08ab3d9909952db43901/parakeet-tdt-0.6b-v2.nemo)
  `d99e39955c9d3d0350d8fb7c75e40c64a2b2eaeb003883d7c941fd2e8747b28c`.
- FluidInference [Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/tree/ee09c569f73759e6d44c9bd16766f477b2b36d39)
  at `ee09c569f73759e6d44c9bd16766f477b2b36d39`. The published card identifies NVIDIA v2 as its
  base; it does not attest the source checkpoint digest. Model and conversion are
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Axo does not modify the export.
- The 21 files in the [size/SHA-256 manifest](../AxoCompanion/Sources/ParakeetAssets.swift) total
  464,413,247 bytes (443 MiB): Preprocessor, Encoder, Decoder, JointDecision and vocabulary.
  They download on demand into a single, purgeable Caches revision; partial downloads aren't used.
- [FluidAudio 0.14.0](https://github.com/FluidInference/FluidAudio/tree/b10bdcb51dcfeedb8001353b4ba363da1a616d6d)
  (MIT) is pinned by `apple/Package.resolved`. Core ML loads only the verified local assets.
  One recognizer is loaded per recording/request and released afterward. No model runs on Watch.

## Verification

The opt-in integration test runs the same runtime on 16 kHz mono PCM (live inference input)
and the Watch file transcriber on a mono AAC variant. This tests inference on the Apple Silicon
Mac, not a hardware microphone or a paired transfer.

```sh
say -v Samantha -r 170 -o /tmp/axo-parakeet-fixture.aiff \
  'Hello world. The little bird is singing in the garden.'
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/axo-parakeet-fixture.aiff /tmp/axo-parakeet-fixture.wav
afconvert -f m4af -d aac -b 32000 -c 1 /tmp/axo-parakeet-fixture.wav /tmp/axo-parakeet-fixture.m4a
bazel test //apple/AxoCompanion:AxoCompanionTests \
  --strategy=TestRunner=local --test_timeout=600 --test_output=all \
  --test_env=AXO_PARAKEET_FIXTURE=/tmp/axo-parakeet-fixture.wav \
  --test_env=AXO_PARAKEET_TEST_CACHE="$(mktemp -d /tmp/axo-parakeet.XXXXXX)"
```

Set `AXO_PARAKEET_EXPECTED` for a different synthetic clip. For a warm-cache offline
check, reuse the populated cache directory, set `AXO_PARAKEET_OFFLINE=1`, and invoke the
built test binary with networking denied:

```sh
bazel build //apple/AxoCompanion:AxoCompanionTests
# Export AXO_PARAKEET_FIXTURE, AXO_PARAKEET_TEST_CACHE and optionally AXO_PARAKEET_EXPECTED.
AXO_PARAKEET_OFFLINE=1 sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  bazel-bin/apple/AxoCompanion/AxoCompanionTests.xctest/Contents/MacOS/AxoCompanionTests
```

The test reports model preparation, PCM inference after preparation, and Watch AAC
end-to-end file transcription (including loading from the cache) separately.
