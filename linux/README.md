# Linux host (initial bring-up)

The shared Rust daemon stays in `crates/`; Linux distribution, service and desktop integration live here. This is an initial x86-64 GNU/Linux build, not a Linux desktop-app release.

## Build

Requirements: Linux 5.11 or newer with `/proc` and devpts, a C/C++ compiler, CMake, Ninja, OpenSSL development headers and pkg-config. Computer use also needs X11, Xi, Xtst and xkbcommon runtime/development libraries (Ubuntu: `libx11-dev libxi-dev libxtst-dev libxkbcommon-dev`). No display server is required for terminal-only daemon operation. Bazelisk selects Bazel from `.bazelversion`; Bazel selects the pinned Rust and Zig toolchains independently of the shell's Rust default.

```sh
bazel build //linux:axod //linux:runtime
```

- Daemon: `bazel-bin/crates/axod/axod`
- Runtime archive: `bazel-bin/linux/axo-linux.tar.gz`

The archive contains the `axo` CLI, `axod`, the pinned `axod-infer` sidecar, `axo-askpass` for sudo input, and the compiled Pi extension under `AxoPi/`. Keep that layout when extracting it. Keep all four executables beside one another: the daemon discovers its helpers relative to its own executable. Linux defaults to CPU inference; MLX and Core ML remain Apple-only.

### Headless archive contract

```sh
bazel test //linux:runtime_test
```

This uses private HOME/XDG directories, sockets and an owned Pi fixture. It checks
CLI-to-daemon health, unlinked status, non-overwriting/idempotent `axo cli install`,
and catalog/host-identity/settings preservation after a graceful stop and restart
from a relocated candidate directory. It neither registers a service nor touches
the installed runtime. Relocation of the same build is not cross-version migration,
signed-update or rollback acceptance. No native terminal or display server is needed.

`bazel test //specs:recovery_test` checks the shared restart/pinned-process
admission models with the pinned Node checker on Linux or Mac. It requires
exhaustive exploration of the bounded models, not just passing sampled walks,
and has unsafe-model negative controls. This is not an exactly-once delivery
claim across process or network crashes.

After extraction, `./axo --socket /absolute/path/to/axod.sock daemon status` checks
a running host. `./axo cli install` adds a non-overwriting link in `~/.local/bin`;
it does not install/update a daemon service. An existing different command/link
is refused. A supported Linux service installer and authenticated update/rollback
flow remain separate work; do not treat CLI link installation as an updater.

### CUDA

Use a CUDA toolkit compatible with the host compiler and NVIDIA driver. It must include nvcc, headers, static cudart, cuBLAS/cuBLASLt and their static dependencies. Driver installation or a reboot is not part of this build. For an RTX 2080 Ti (compute capability 7.5):

```sh
bazel build //linux:runtime \
  --repo_env=AXO_LLAMA_BACKEND=cuda \
  --repo_env=AXO_CUDA_ARCHITECTURES=75 \
  --repo_env=CUDA_PATH=/absolute/path/to/cuda
```

Other explicit architecture lists use semicolons (quote the argument). `native` is deliberately rejected: build support must not silently depend on GPUs present on the builder. `AXO_LLAMA_BACKEND=cpu` explicitly selects a toolkit-free CPU artifact. macOS continues to default to embedded Metal.

CUDA user-space libraries are linked statically. The target still needs its NVIDIA driver's `libcuda.so.1`, but not the toolkit or a custom `LD_LIBRARY_PATH`. Verify the extracted helper with `ldd`, `readelf -d` and `axod-infer --list-devices`. The inference capabilities inventory reports `compiledAccelerator`; that is a build capability, not proof of GPU availability or successful offload. The existing runtime automatically places model layers; the public backend stays `llama.cpp`.

A manual service acceptance test downloads a pinned, SHA-256-verified Qwen2.5 0.5B GGUF into a separate `/tmp/axo-linux-gguf-models` cache, performs two real generations, checks reuse and retirement, and requires offload evidence for CUDA builds:

```sh
bazel test //crates/axod-infer:gguf_service_smoke_test //crates/axod-infer:gguf_cpu_smoke_test \
  --local_test_jobs=1 \
  --repo_env=AXO_LLAMA_BACKEND=cuda \
  --repo_env=AXO_CUDA_ARCHITECTURES=75 \
  --repo_env=CUDA_PATH=/absolute/path/to/cuda \
  --test_output=all
```

Use the same repository options for related builds/tests to avoid rebuilding the native helper with a different accelerator. Run `//third_party/llama.cpp:repository_test` for fast configuration checks. These are functional checks, not performance benchmarks.

## Isolated bring-up

Do not point an experimental build at a real Axo state directory. To start without production relay access:

```sh
run=$(mktemp -d)
bazel-bin/crates/axod/axod \
  --server-dir "$run/server" \
  --socket "$run/axod.sock" \
  --relay-url http://127.0.0.1:9
```

For a self-contained smoke test with a sleeping Pi fixture and no real account or user state:

```sh
python3 linux/smoke.py bazel-bin/crates/axod/axod
# After extracting the runtime archive:
python3 linux/smoke.py --bundled-resources /path/to/extracted/axod
```

This checks health RPC, session creation, terminal input/output, session close, and clean SIGTERM shutdown. It does not validate a real Pi model turn or account linking.

Logs go into the specified server directory. The daemon defaults to private file-based host credentials on Linux; it does not use or emulate Apple's Keychain.

## Computer use

The daemon embeds the pinned Cua Linux runtime and exposes Axo's allowlisted computer tools plus Linux secure-input target discovery. The allowlist is enforced inside the registry, including nested scripts/batches. Every dispatch rechecks desktop lock state; a missing, inactive, ambiguous or unverifiable logind graphical session fails closed. This does not grant a same-UID client permission to answer an Axo confirmation.

Start from the graphical user's session or its systemd user manager so the daemon inherits `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`/`XAUTHORITY` and/or `WAYLAND_DISPLAY`. For native Wayland, explicitly set `CUA_DRIVER_RS_ENABLE_WAYLAND=1` in that daemon's environment. A reachable XWayland display does not prove native Wayland capture/input support. The adapter never starts a nested compositor or installs a GNOME extension implicitly.

**GNOME 50 limitation:** the pinned WinRects helper is deliberately disabled because of session-ending native crashes. Do not bypass that guard or enable an older helper on GNOME 50. An active helper on an unsupported/unverifiable GNOME version is refused before desktop dispatch. Without it, Cua can return an AT-SPI tree with a typed `screenshot_error`; per-window capture and verified focus-bound input remain unavailable. Compositor-specific behavior beyond the tested X11 path needs separate acceptance. Linux capture/input may require portal consent. The `screenRecording` status field is an observed capture capability on Linux, not an Apple TCC grant.

**Sudo input:** Linux `request_input` runs an explicitly approved noninteractive command with `args: { target: { kind: "sudo", argv: ["/absolute/program", ...] } }`. The calling Session selects the directory. The person first approves the exact command and, if sudo asks, enters one password on their own device. `axo-askpass` hands it to sudo’s private pipe, never a terminal or tool result. Only an exit receipt returns; command stdout/stderr are discarded. Cancellation after authorization cannot roll back a command—never retry an uncertain invocation automatically. Sudo policy is unchanged; this does not enable passwordless sudo. See [RFD0059](../docs/rfds/RFD0059-linux-sudo-input.md).

**GUI input (in progress):** native Linux form binding is being implemented through exact AT-SPI objects, numeric password roles, process/window/document checks and direct accessibility edits. The isolated GTK fixture exercises real email/password delivery, submit and stale-field refusal. Browser acceptance is not complete: the Firefox fixture currently rejects edits that it cannot confirm. Do not substitute keyboard/clipboard typing or claim all browsers work. The conservative privacy path withholds screenshots after GUI input and persists salted substring fingerprints before any fill, so restart cannot discard protection. See [RFD0080](../docs/rfds/RFD0080-linux-gui-input.md). Existing terminal prompts remain unsupported.

Use `computer({tool:"input_targets",args:{pid}})` to discover an application\'s 64-bit AT-SPI window handles, then `input_targets` with `{pid,window_id}` to inspect its executable, title, document origin, field labels, secure roles and buttons. Discovery is read-only, available in nested scripts, and does not collect or return field values. `binding_available` describes the inspected fields, not a promise that the application will accept a write; each requested fill must still confirm delivery. Unsupported bindings return errors before any person-input request. Compositor IDs are not interchangeable with these handles, and discovery IDs can become stale. Standard observation is promptless; permission modes requiring scoped observation grants fail closed until exact AT-SPI grant scopes are implemented.

For an isolated desktop acceptance test, install Xvfb, Openbox, xauth, D-Bus, system Python GI and GTK 4 introspection data (`xvfb openbox xauth dbus-x11 python3-gi gir1.2-gtk-4.0` on Ubuntu). Then:

```sh
bazel build //crates/axo-computer:linux_desktop_smoke_test
linux/computer-smoke.sh bazel-bin/crates/axo-computer/linux_desktop_smoke_test
```

Pass the same CUDA repository options if testing a CUDA build. The launcher owns a private X11/D-Bus session and harmless GTK window; it never unlocks or reads the real desktop. It checks enumeration, accessibility, screenshot capture, edit/readback, a button action, stale-token rejection and lock changes during a script. Its test-only guard models that owned virtual session, not the host's logind session. This is **X11 evidence, not GNOME Wayland parity**. A separate ignored test verifies the actual locked-session refusal without capturing user content.

`linux/check.sh` accepts additional Bazel options and checks the archive plus focused shared suites, including computer-use gates. It does not run interactive desktop/model acceptance or restart/install the paired daemon.

## Native desktop prototype

[`AxoDesktop/`](AxoDesktop/README.md) contains the Rust/GTK4 window hosting the pinned Ghostty GTK renderer. Build/run it with `bazel run //linux/AxoDesktop:run` on a Linux development host with its native dependencies. Its isolated fixture tests real rendering, PTY keyboard input, resize and widget teardown without driving the real desktop.

The candidate now has a first local Session sidebar and persisted split-pane workbench through an explicitly selected daemon, plus single-shell attachment and separate standalone development modes. It also has native daemon settings and optional StatusNotifierItem/DBusMenu integration. It is **not yet Mac feature parity** or an installer; exited-Pi recovery, close/archive, layout writes and remaining controls are pending. A separate UI owner now wakes only a foreground selected Dormant Pi, with serial unavailable-only requests, conservative attempt fencing and no force fallback. Explicit current-context/Home/native-folder creation now uses typed shared RPCs with one pending intent, authoritative selection and no automatic retry after an uncertain reply. Native viewport publication now uses actual Ghostty metrics and an independently negotiated v2 method, preserving Mac v1 and legacy storage. Live catalog subscriptions and read-only reconnect use one shared Rust watcher; the isolated reconnect driver cuts catalog and attach transports without restarting its fixture daemon or replaying input. Attachment requires the candidate's captured-grid v3 protocol; the server keeps v2 compatible for existing Mac clients. It never upgrades/restarts the paired daemon implicitly. The [Mac feature map and shared-core contract](../docs/rfds/RFD0054-linux-desktop.md) define the path to the full workbench; session/account/storage logic stays in shared Rust rather than becoming a separate Linux backend. The CLI is also available separately at `//crates/axo-cli:axo` and is bundled in the headless runtime archive.

## Blocked-input hardening gate

`scenarios::prompts::a_pane_that_takes_no_input_holds_up_only_its_own_writers`
now passes on this branch, together with `stopping_axod_ends_a_blocked_input_writer`.
Both run in owned subprocesses with 25-second parent watchdogs: a stranded Tokio
blocking-pool thread becomes a named test failure rather than hanging the suite.
The parent kills/reaps only its own worker; each fixture owns its database,
directory and PTYs. This fix has **not** replaced/restarted the installed runtime.
Run with a larger outer Bazel timeout (and the same dependency options as your build):

```sh
bazel test //crates/axo-server:axo_server_tests \
  --test_arg=scenarios::prompts::a_pane_that_takes_no_input_holds_up_only_its_own_writers \
  --test_arg=--exact --test_timeout=40 --test_output=all
```

Investigation on starbase2 found a blocking 48,000-byte master write returning
15,872 bytes as the fixture pane closed, then blocking again on the remaining
32,128 bytes. The per-pane Condvar deadline works for a waiting writer; it cannot
interrupt the active libc write. An async timeout likewise cannot stop that
blocking task, so runtime destruction can hang after the scenario panics.

A zero-time `poll` hangup check before each write was tried and **discarded**:
it passed one complete server/PTY run but still timed out in one of ten isolated
reruns. A separate raw-writer probe could remain in its first write after child
exit. Polling before a blocking syscall does not establish a cancellation contract.
Input flushing likewise did not release a first blocked write in an owned probe.

The Linux pane owner now stops its child, stops the output pump and retires the
**exited** terminal using `TIOCSETD(N_NULL)`, off the async thread. This irreversible
kernel error-handling line discipline wakes existing I/O and refuses subsequent
reads/writes, including through retained attachment copies. The helper verifies
child exit and refuses a live/unconfirmed child. It never runs on widget detach,
selection change, resize or live input. The worker owns the pane/descriptors until
retirement completes, with correlated failure logs and no unsafe fallback.

Linux can report `EAGAIN` on a blocking master while its line discipline changes.
The writer now returns that error rather than polling a retired terminal for
`POLLOUT`. Readiness waiting remains supported for already-nonblocking descriptors;
production never sets shared master `O_NONBLOCK`. CLOEXEC/ownership, v2/v3 framing,
normal live input and Mac's existing runtime path are unchanged. This does **not**
make an active write to a live, non-reading child deadline-bound; the fix is for
pane/daemon teardown, not arbitrary request cancellation or automatic write retry.

On starbase2/Linux 7.0, all 90 server and 54 PTY cases pass in ten complete repeated
runs, with no skipped regression. Tests cover daemon shutdown, another pane staying
responsive, live-retirement refusal, retained master copies/late writes and unchanged
status/CLOEXEC flags. Native Mac tests and a broader Linux kernel/distribution matrix
have not been rerun. All eight focused Bazel suites (server, PTY, IPC, protocol,
client, CLI unit/e2e and desktop units) pass, as do all five isolated GTK drivers.
Those drivers validate real Ghostty rendering/detach behavior under Xvfb and a
simulated tray host, not native GNOME/Wayland or hardware-panel acceptance.
No installed daemon or real Session was used as a fixture.

## Boundaries

- PTY creation uses Linux grantpt/unlockpt/ptsname_r. Child descriptor inheritance uses `close_range(CLOSE_RANGE_CLOEXEC)` and fails closed if unsupported.
- Process identities include the kernel's start time; a matching PID alone is not sufficient for cleanup after daemon restarts.
- Computer use is compositor-dependent as described above. GNOME 50 window capture/focus-bound input and Linux secure form input are not implemented/validated parity.
- Privileged local IPC calls still fail closed outside macOS. A Linux tray must not bypass those checks or treat a matching Unix UID as equivalent to an Apple code signature. Linux client authorization needs a separate design before enabling question answers or other privileged app actions.
- Apple model metadata is omitted. Pairing, registration and daemon status identify Linux explicitly on the wire; some account clients may still present a macOS label. General Linux model/OS identification, browser launching, XDG model/cache paths, persistent systemd user-service installation, and Linux CI remain follow-up work.
- Optional native StatusNotifierItem support lives under `linux/AxoDesktop`, using GIO rather than a GTK3 shim or shell modification. Hide requires a confirmed live host; host/watcher loss restores a hidden window, and absent support remains window-only. Acceptance uses a simulated watcher/host; real desktop-panel validation, tray branding, question badges and autostart/install lifecycle remain pending.

The original Apple targets remain under `apple/`. Building `//...` is not the Linux support contract: use Linux targets and the shared Rust test suites.
