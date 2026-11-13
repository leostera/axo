/** Model-specific facts belong in fixtures, never in the production API's accepted model set. */
export const GEMMA = {
  model: "hf:ggml-org/gemma-3-270m-it-GGUF",
  source: {
    repo: "ggml-org/gemma-3-270m-it-GGUF",
    revision: "e7647be17ae1108f2f605ed061ca0608b171afff",
    file: "gemma-3-270m-it-Q8_0.gguf",
    sha256: "0ef57d2c838458a1952664260dcba38e5bdda37494f3af732f06e4add24068e3",
    files: [{ path: "gemma-3-270m-it-Q8_0.gguf", bytes: 291_545_600, sha256: "0ef57d2c838458a1952664260dcba38e5bdda37494f3af732f06e4add24068e3", role: "model" as const }],
  },
};
