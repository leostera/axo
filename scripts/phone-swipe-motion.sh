#!/usr/bin/env bash
# Records the simulator while AxoPhoneMotionTests swipes between layers, then follows the magenta
# stripe the app draws on the conversation layer's edge, frame by frame. Prints, per swipe, how
# the layer moved, and flags snaps: its speed changing all at once, as a canned jump on release does.
#
#   scripts/phone-swipe-motion.sh            # record and analyse
#   scripts/phone-swipe-motion.sh VIDEO.mp4  # analyse an existing recording
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${AXO_PHONE_MOTION_DIR:-/tmp/axo-phone-motion}"
mkdir -p "$OUT"
VIDEO="${1:-}"
cd "$ROOT"

if [[ -z "$VIDEO" ]]; then
  VIDEO="$OUT/swipes.mp4"
  DEVICE_NAME="BAZEL_TEST_iPhone 17_27.0"
  UDID="$(xcrun simctl list devices available -j | python3 -c "
import json, sys
for runtime in json.load(sys.stdin)['devices'].values():
    for d in runtime:
        if d['name'] == '$DEVICE_NAME': print(d['udid'])" | head -1)"
  if [[ -z "$UDID" ]]; then
    echo "No simulator named '$DEVICE_NAME'; run the phone UI tests once to create it." >&2
    exit 1
  fi
  xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl bootstatus "$UDID" -b >/dev/null

  # Build first, so the recording holds the swipes and not the build.
  bazel build //apple/AxoPhone:AxoPhoneUITests --ios_multi_cpus=sim_arm64 >/dev/null 2>&1

  rm -f "$VIDEO" "$OUT/record.log"
  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$VIDEO" 2>"$OUT/record.log" &
  RECORDER=$!
  for _ in $(seq 1 50); do grep -q "Recording started" "$OUT/record.log" 2>/dev/null && break; sleep 0.1; done

  status=0
  bazel test //apple/AxoPhone:AxoPhoneUITests --ios_multi_cpus=sim_arm64 --nocache_test_results \
    --test_filter='AxoPhoneMotionTests' --test_output=errors >"$OUT/test.log" 2>&1 || status=$?
  kill -INT "$RECORDER"
  wait "$RECORDER" || true
  if [[ $status -ne 0 ]]; then
    echo "The motion test failed; see $OUT/test.log" >&2
    tail -20 "$OUT/test.log" >&2
    exit $status
  fi
fi

read -r WIDTH HEIGHT < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$VIDEO" | tr ',' ' ')
ROW=$((HEIGHT * 40 / 100))
ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$VIDEO" >"$OUT/times.txt"
ffmpeg -v quiet -i "$VIDEO" -fps_mode passthrough -vf "crop=${WIDTH}:2:0:${ROW}" -f rawvideo -pix_fmt rgb24 - >"$OUT/rows.rgb"

python3 - "$OUT/times.txt" "$OUT/rows.rgb" "$WIDTH" <<'PY'
import sys

times_path, rows_path, width = sys.argv[1], sys.argv[2], int(sys.argv[3])
scale = 3.0  # device pixels per point on the recorded iPhone
times = [float(line.split(",")[0]) for line in open(times_path) if line.strip()]
data = open(rows_path, "rb").read()
row = width * 3  # first of the two rows cropped per frame
frames = []
for i, t in enumerate(times):
    pixels = data[2 * i * row:(2 * i + 1) * row]
    if len(pixels) < row:
        break
    xs = [x for x in range(width) if pixels[3*x] > 200 and pixels[3*x+1] < 90 and pixels[3*x+2] > 200]
    if xs:
        frames.append((t, sum(xs) / len(xs) / scale))

if not frames:
    raise SystemExit("No marker found: was the app launched with AXO_PHONE_PREVIEW_MARKERS=1?")

# Split into movements: runs of frames where the stripe moves, separated by rests.
movements, current = [], []
for prev, frame in zip(frames, frames[1:]):
    # The recorder writes a frame only when the screen changes, so a pause shows as a gap.
    if current and frame[0] - prev[0] > 0.3:
        movements.append(current)
        current = []
    moving = abs(frame[1] - prev[1]) > 0.25
    if moving:
        if not current:
            current = [prev]
        current.append(frame)
    elif current and frame[0] - current[-1][0] > 0.25:
        movements.append(current)
        current = []
if current:
    movements.append(current)

print(f"{len(frames)} frames with the marker, {len(movements)} movements\n")
# A snap is the stack's speed changing all at once: hundreds of points in one frame. A spring, a
# finger, or a push easing back changes speed a little every frame.
JUMP = 2500  # points a second, from one frame to the next
problems = 0
for n, m in enumerate(movements, 1):
    start, end = m[0][1], m[-1][1]
    duration = m[-1][0] - m[0][0]
    gaps = [b[0] - a[0] for a, b in zip(m, m[1:])]
    speeds = [(b[1] - a[1]) / max(b[0] - a[0], 1 / 120) for a, b in zip(m, m[1:])]
    jumps = [abs(b - a) for a, b in zip(speeds, speeds[1:])]
    biggest = max(jumps, default=0)
    late = sum(1 for g in gaps if g > 1.5 / 60)
    flags = []
    if biggest > JUMP:
        flags.append(f"SNAPS: speed changed by {biggest:.0f} pt/s in a frame")
    if late:
        flags.append(f"{late} late frames")
    problems += biggest > JUMP
    print(f"movement {n}: {start:6.1f} -> {end:6.1f} pt in {duration*1000:4.0f} ms, {len(m)} frames, "
          f"top speed {max((abs(v) for v in speeds), default=0):5.0f} pt/s, largest change of speed {biggest:5.0f} pt/s"
          + (f"   <-- {', '.join(flags)}" if flags else ""))
    path = " ".join(f"{x:.0f}" for _, x in m[::max(1, len(m) // 24)])
    print(f"   x: {path}")
print("\nno snaps" if not problems else f"\n{problems} movement(s) snap")
sys.exit(1 if problems else 0)
PY
