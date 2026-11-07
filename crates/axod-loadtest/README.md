# axod-loadtest

Load test for axod. It starts its own isolated daemon (temporary HOME and server directory, the Pi fixture instead of Pi), puts background load on it (catalog and terminal-output subscribers, output floods, attach churn, Session and shell lifecycle), and measures control-plane latency from probe threads on persistent apps. It exits non-zero when a request fails or a latency budget is exceeded.

Never point it at a person's daemon; it never connects to one.

```sh
bazel run -c opt //crates/axod-loadtest -- --profile heavy
bazel run -c opt //crates/axod-loadtest -- --profile smoke --seconds 5
```

| Profile | Load | Pass bar |
| --- | --- | --- |
| `heavy` (default) | 8 Sessions × 3 terminals, 32 catalog and 4 stream subscribers, 4 flooders, 2 attach churners, 4 probes, 20 s | control-plane p99 < 10 ms, lifecycle p99 < 100 ms |
| `smoke` | 2 × 2, light load, 3 s | p99 < 250 ms (guards against stalls on a busy machine) |

`--axod` and `--pi-fixture` default to `$AXOD_BINARY` and `$AXO_TEST_PI_EXECUTABLE`; `bazel run` sets both.

| Module | Owns |
| --- | --- |
| `main` | Profiles, setting up Sessions, and the load and probe threads |
| `daemon` | The isolated axod for one run |
| `client` | A minimal typed JSON-RPC client on axod's socket |
| `stats`, `metrics` | Latency and error accounting and the report; the daemon's threads, descriptors and memory |

## Test

```sh
bazel test //crates/axod-loadtest:unit_tests //crates/axod-loadtest:smoke_test
```
