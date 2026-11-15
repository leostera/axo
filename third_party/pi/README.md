# Pi message-free continuation prerequisite

Axo's automatic restart continuation requires a Pi build exposing `ExtensionAPI.resumeTurn()`.
The ordinary installed SDK does not expose it. Older SDKs explicitly refuse recovery; Axo must
not fall back to a user prompt or hidden custom message.

`resume-turn.patch` adds the capability to [earendil-works/pi](https://github.com/earendil-works/pi),
tag `v1.4.0`, commit `4a080252f06caf63a525d7873c5d94d3c23887e0`.
The upstream MIT license is included. This patch is not automatically applied, installed, or
published by Axo's build. **Do not claim this feature works on an unmodified host SDK.**

## Contract

- `AgentSession.resumeTurn(): Promise<void>` enters the normal run lifecycle with a
  `before_agent_start` event whose `messageType` is `"resume"`, with no starting message.
- `ExtensionAPI.resumeTurn(): void` delegates to that session method; asynchronous errors use
  the normal extension error channel.
- Busy/compacting sessions and empty context are refused. Model selection, system/tool
  preparation, tool interception, abort, retry, compaction and settlement retain their normal
  lifecycle. Existing user/custom-start behavior is unchanged.
- Saved completed tool calls are not automatically replayed. This is not exactly-once external
  side-effect recovery, nor a guarantee that a model won't propose another tool call.

## Applying and validating

Apply only to the pinned source, following upstream development setup, including its ignored
provider-model data. No dependency or lockfile changes are part of the patch:

```sh
git apply --check /path/to/axo/third_party/pi/resume-turn.patch
git apply /path/to/axo/third_party/pi/resume-turn.patch
npm run check
cd packages/coding-agent
node ../../node_modules/vitest/dist/cli.js --run \
  test/suite/agent-session-resume-turn.test.ts \
  test/suite/agent-session-prompt.test.ts \
  test/suite/agent-session-boundaries.test.ts \
  test/extensions-runner.test.ts --maxWorkers=2
```

The selected SDK regression run passes 112 tests, including six new resume cases. The SDK's
full `npm run check` passes. The entire upstream test suite was not run.

Axo also has a portable real-SDK/socket/provider test that checks both supported and explicitly
unsupported hosts. To require the supported path against the patched source:

```sh
cd /path/to/axo
AXO_TEST_REQUIRE_RESUME_TURN=1 node_modules/.bin/tsx \
  --tsconfig /path/to/pi/tsconfig.json \
  --test packages/pi-axo/test/resume-turn-sdk.test.ts
```

That run checks one actual faux-provider call despite duplicate controls, one original user
message, and no custom-message trigger. Tests use private temporary session directories and no
real provider credentials or production Sessions.
