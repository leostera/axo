# RFD0050 - Axo: per-run codemode limits

- Feature Name: `codemode-run-limits`
- Status: Implemented (Axo 0.60)
- Release: Mac 331 / axod 81, commit `e581e69a0bacceb39b31d2f4e4cd68d78c6a8d26`; Worker deployment `238c1a8b-faae-407d-ae3f-ce652a8d222a`
- Author: leostera
- Start Date: 2026-11-14
- Updated: 2026-11-14
- Document Type: Proposal
- Amends: [RFD0016](RFD0016-connections-and-tools.md), [RFD0042](RFD0042-async-relay-and-extensions.md)

## Summary

Let `apps_run` request smaller `limits: { timeoutMs, maxToolCalls, maxConcurrentCalls, maxOutputBytes }` within existing server ceilings. The account owns one run budget, its deadline, queued calls and cancellation. The run closes admission before cancelling owned work; a timeout is not evidence that an external action did not happen.

## Motivation

A short query and a multi-model script should not have to use the same fixed budget. The existing runner races a five-minute timer but does not cancel pending work; host tools have their own independently computed deadlines, bash reserves no response grace, and only result string length is bounded rather than UTF-8 output including logs. An agent needs predictable bounds and honest retry semantics.

## Guide-level explanation

```js
{
  code: "async () => await codemode.bash.run({host:'self',command:'echo hello'})",
  limits: { timeoutMs: 10000, maxToolCalls: 2, maxConcurrentCalls: 1, maxOutputBytes: 65536 }
}
```

Omitting limits preserves the five-minute/100-call/four-concurrent defaults. Each field is a positive integer, at most its published ceiling. Invalid, unknown or excessive limits are rejected before executing script code, not silently clamped. `maxOutputBytes` counts the UTF-8 JSON response envelope `{result,logs}`; exceeding it fails instead of returning a partial value. Script source size and provider/host-specific limits remain independent.

## Reference-level explanation

- Parse requested budgets in the shared protocol; expose the same optional object in MCP. Existing code-only callers continue to work. Hard ceilings remain 300,000 ms, 100 calls, 4 concurrent calls and 1,048,576 output bytes. A smaller call budget also bounds effective concurrency.
- One account-side run object owns a fixed deadline, cancellation signal and call lifecycle. Check it at admission, after queue waits, and after asynchronous preparation before dispatch. No queued or nested request may start after closure. Swallowing a limit exception does not restore the budget.
- Timeouts bound execution, with a separate bounded cleanup/transport grace inside the existing 330-second forwarding timeout. The script cannot increase its budget through nested tool timeout fields. Host and HTTP calls receive the remaining budget; checks repeat after credential/presence/logging awaits before sending an action.
- Close the dispatcher on success, failure and timeout, cancel supported in-flight requests and release sandbox RPC resources. An unawaited tool call is not a background-job primitive.
- Host jobs receive cancellation scoped to the account and unique call ID on the current relay connection. Cancellation never touches another script’s jobs or the independent computer-use safety judge. Bash cancellation must kill and reap its own shell/process group while retaining its slot; dropping its future alone is unsafe. Native inference retains its existing retirement/kill/reap ownership. Computer actions already applied cannot be undone.
- Provider HTTP and MCP requests combine the run signal with adapter/SDK timeouts rather than replacing either. MCP SDK 1.32.2 sends `notifications/cancelled` from `shared/protocol.js` but `client/streamableHttp.js` uses one transport-wide HTTP signal. Bind a private request correlation ID to its run signal, strip that ID before forwarding, and abort only the affected fetch; aborting the shared transport would cancel other scripts. The account also owns console records and their incremental UTF-8 byte charge; worker-provided logs/limit flags are not trusted. Check cancellation before any retry or subsequent request. A dispatched external write, linked-device action or non-interruptible computer action may have run; cancellation is not rollback. Older hosts without cancellation support retain their bounded timeout and are reported conservatively, never as definitely cancelled.
- Put uncertainty first when a run ends with pending/dispatched work or violates a budget, so the warning survives the relay’s 256-character error limit. Preserve a completed, known tool failure’s actionable sign-in/recovery message instead of prepending a misleading unknown-outcome warning.
- Keep call logging and account/host authorization. Do not log script source, returned data or credentials as part of budgeting. Log a dispatched call with an unknown outcome if cancellation prevents its receipt. No automatic retries of uncertain actions.
- Console log RPCs flush before the next tool dispatch or script return. A swallowed console/output violation is terminal just like a call-budget violation; the account never returns forged worker console records. Opaque linked-device actions and an already-sent external action cannot be rolled back. Phone connection opens that finish after their wait was abandoned are closed rather than orphaned.
- The outer agent harness owns its own deadline. Axo publishes its effective bounds and grace, but cannot reconfigure an arbitrary caller’s timeout; do not claim to eliminate that independent boundary.

## Invariants and tests

- Malformed limits execute no script or tool. Defaults and each ceiling have protocol/MCP regression tests.
- Admission/call/concurrency limits are enforced account-side, including parallel calls, queued calls, thrown/caught errors and detached promises.
- Closing a run prevents further dispatch; owned cleanup remains responsible for termination. The bounded logical protocol in `specs/apps/run-limits.ts` models admission, slots, closure and eventual owned cleanup; it does not claim network-fault liveness or cancellation delivery guarantees.
- Output uses actual UTF-8 JSON bytes, including multibyte strings and logs; no partial successful values on overflow.
- Isolated Worker/relay/daemon tests exercise a short timeout, command-group cleanup, no delayed marker write, subsequent-call recovery, concurrent runs and cancellation isolation. Existing inference ownership and independent-judge tests remain gates.

## Drawbacks and alternatives

- Cancellation crosses several owners and cannot revoke an external side effect. Prefer an explicit uncertain error to a misleading cancelled/safe-to-retry claim.
- Lowering limits is not permission to raise platform ceilings or bypass provider limits. Long-running/background jobs need a separate durable job contract, not a larger synchronous wait.
- Merely adding schema fields or changing the timeout race would leave detached work running. Using per-request relative timeouts without a fixed run deadline allows preparation and queues to extend the run. Doing nothing leaves every script on the same budget.
- CPU/memory quotas, arbitrary outer-harness control, transactional rollback and automatic migration of sessions are out of scope.
