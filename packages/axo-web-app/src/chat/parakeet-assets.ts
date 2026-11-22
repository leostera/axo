// NVIDIA Parakeet TDT 0.6B v3, converted by istupakov and repackaged by ysdede.
// The exporter does not record the original NVIDIA repository commit. See the package README.
const repository = "https://huggingface.co/ysdede/parakeet-tdt-0.6b-v3-onnx";
const revision = "e5356bf6e24bdb7a269536b0e9e7869bc034b893";

export interface Asset {
  url: string;
  bytes: number;
  sha256: string;
}

function modelAsset(name: string, bytes: number, sha256: string): Asset {
  return { url: `${repository}/resolve/${revision}/${name}`, bytes, sha256 };
}

export const modelAssets = {
  encoder: modelAsset("encoder-model.int8.onnx", 652183999, "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09"),
  decoder: modelAsset("decoder_joint-model.int8.onnx", 18202004, "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70"),
  tokenizer: modelAsset("vocab.txt", 102132, "ba8e4007c65f4bb4358ffe2ecc13d9ccc7a10351151065242b5c3a943e685742"),
};
export const modelBytes = Object.values(modelAssets).reduce((sum, asset) => sum + asset.bytes, 0);
export const parakeetCacheName = "axo-parakeet-v1";
export const runtimeBytes = 24_911_187;
export const dictationDownloadMB = Math.ceil((modelBytes + runtimeBytes) / 1_000_000);

export const dictationSampleRate = 16_000;
export const maxDictationSamples = 60 * dictationSampleRate;

export type ModelRequest =
  | { kind: "prepare"; download: boolean }
  | { kind: "transcribe"; pcm: Float32Array };

export type ModelReply =
  | { kind: "needsDownload" }
  | { kind: "downloading"; percent: number }
  | { kind: "loading" }
  | { kind: "ready" }
  | { kind: "transcript"; text: string }
  | { kind: "failed"; message: string };
