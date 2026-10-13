# pi-axo

Axo's TypeScript extension loaded **inside the user's ambient vanilla Pi**. This is the Pi-facing adapter, not the daemon or an embedded Pi runtime.

- `index.ts`: managed interactive control extension using public Pi APIs.
- `control-protocol.ts`: typed responses/errors/events mirrored by closed Rust serde types in `axod/src/pi_control/wire.rs`; `index.ts` validates requests with a method-discriminated, closed Zod union.
- `questions.ts`: public `axo_ask`, one offered-option question shared by the local selector and captured remote answer; cancellation/invalid values never approval.
- `tests/fixtures/provider.ts`: controlled loopback provider and real interactive-tool/input-hook fixtures, loaded into actual Pi during integration tests.

The Rust daemon in `../axod/` owns PTYs, child supervision, work records, RPC and journals. This extension observes actual Pi identity/lifecycle and invokes public message, steering, abort and read-only session APIs in that same interactive process. Pi alone owns execution, queues, dialogs and canonical history.

The extension activates only with the explicit `--axo-managed-control` flag and an owner-created anonymous socket inherited at fd 3. It does not open a listener, launch another agent, use Pi RPC mode, parse terminal text for controls or write transcripts. Losing control does not abort accepted work. Dispatch acknowledgement is not completed execution; ambiguous dispatch is fenced rather than replayed.

## Development

```sh
./node_modules/.bin/tsc -p pi-axo/tsconfig.json
npm run test:pi-interactive
```

The root Pi dependency supplies development declarations only; execution uses the normal ambient launcher, never the repository package. No live Pi installation or application configuration is changed by these commands.

See [the current integration evidence and remaining gates](../axod/pi/README.md). The central daemon owns Pi startup and exact resume; the former client `axo.session.start` contract is retired. Required public Pi control, history and cooperative writer machinery remains, but central observation/control/submitted-input routes and native/primary-phone consumer parity are not complete. This folder does not replace or migrate the independently owned legacy `bridge/`.
