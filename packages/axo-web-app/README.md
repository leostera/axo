# Axo web application package

This package owns the React application (chats with Axo on your Macs, in the iPhone app's look), browser API/relay integration, styles, and tests. The unified deployment shim, HTML document, and Cloudflare configuration live in `sites/axo.leostera.dev`.

## Development and validation

From the repository root:

```sh
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app install
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app run typecheck
npm --userconfig=/tmp/axo-npmrc --prefix packages/axo-web-app test
```

The app targets `https://axo.leostera.dev` by default; set `VITE_AXO_API_BASE_URL` to target an isolated API during development. The `/app` path checks the same-origin `/api/auth/*` session and, when signed in, opens the chats: the iPhone app's layers (account, chats, conversation, chat info), side by side from 900px wide and stacked below that. The chats are listed in one list by recent activity, as on the Mac. The open chat is in the URL (`/app/<hostId>/<sessionId>`), so a reload or a link opens it again and Back and Forward move between chats. The components follow the iPhone app's (`apple/AxoMobile`): the composer offers on-device dictation on supported desktop browsers, with a waveform, Cancel, Stop (into the box) and Send; what Axo is doing shows under the last message with a Stop that asks first. The browser follows chats, not terminals: it reads history newest first, a page at a time, and sends messages, stops and answers as the phone does. `src/chat/{markdown,transcript,workbench}.ts` are ports of the phone's `AxoMobileModel` and are tested directly with `npm run test:model`; `AXO_WEB_SHOTS=<dir> npm run test:browser` keeps a screenshot of each step. Set `VITE_AXO_AUTH_API_BASE_URL` only when testing against a separate isolated API origin.

## On-device dictation

Talk asks before the first ~696 MB download. Axo checks and caches the files in the browser, then opens the microphone. Stop transcribes locally and appends the text to the draft; Send transcribes locally and sends only the text through the usual composer. Cancel or a dictation failure leaves the typed draft alone. Recordings stop after one minute and go to the draft. Mobile browsers show dictation as unavailable. Some private browsing profiles do not provide enough storage. Clearing the site's browser data also removes the cached model. After setup, a visible desktop composer can verify and load the cached model and WASM runtime in the background. Talk reuses that work but is still required to open the microphone. Incomplete caches never trigger a background download.

The reference checkpoint is [NVIDIA Parakeet TDT 0.6B v3 at `541d1f99`](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/tree/541d1f99c6b0c3cd0b11a95167540bb8edefd82b), by NVIDIA, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The browser worker uses the [int8 ONNX export repackaged by ysdede](https://huggingface.co/ysdede/parakeet-tdt-0.6b-v3-onnx/tree/e5356bf6e24bdb7a269536b0e9e7869bc034b893) from [istupakov's ONNX conversion](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/tree/8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce). The exporter identifies the v3 model but does not record its NVIDIA source commit, so we cannot attest that the derivative comes from that exact checkpoint. The derivative revision, sizes and SHA-256 digests are pinned in `src/chat/parakeet-assets.ts`. The npm lockfile pins Parakeet.js and ONNX Runtime Web; the worker checks the bundled WASM binary's SHA-256 before passing it to ONNX Runtime. The worker verifies cached bytes on reload too. There is no browser speech service, WebGPU backend, audio upload, or runtime CDN.

Run the opt-in desktop Chrome acceptance test with a supplied synthetic WAV. It downloads the real assets, feeds the fixture through the capture graph, checks Stop/Send/Cancel, blocks model network access on reload, and tests a corrupted cache. To reproduce the default fixture on macOS:

```sh
say -o /tmp/axo-notebook.aiff "The blue notebook is on the kitchen table."
ffmpeg -i /tmp/axo-notebook.aiff -ar 16000 -ac 1 -c:a pcm_s16le /tmp/axo-notebook.wav
AXO_PARAKEET_FIXTURE=/tmp/axo-notebook.wav pnpm --dir packages/axo-web-app test:parakeet
```

Set `AXO_PARAKEET_TEXT` to the expected words if using another fixture. `CHROME_PATH` overrides the browser executable. Set `AXO_PARAKEET_BENCH_RESULTS` to a JSON output path to measure five reloads per condition: click as soon as Talk is enabled, or wait 20 seconds first. The timer runs from the Talk click event to the Listening DOM update. It uses the real WASM model and capture graph with a synthetic stream, so it excludes physical microphone and permission-prompt latency.

Production Cloudflare consent, callback, session verification, account-scoped host routes, and host pairing have succeeded. The retired `app.axo.leostera.dev` and `api.axo.leostera.dev` Workers and site shims are not part of the product flow. Legacy global `private-fleet` host records remain unassigned and are not shown in account Workbench.
