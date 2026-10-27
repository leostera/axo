#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-verify}"
case "$MODE" in
  verify|record) ;;
  *) echo "usage: $0 [verify|record]" >&2; exit 2 ;;
esac

SNAPSHOTS="$ROOT/apple/AxoPhone/Snapshots/Phone"
ARTIFACTS="${AXO_PHONE_VISUAL_ARTIFACTS:-/tmp/axo-phone-visual}"
RESULT="$ROOT/bazel-testlogs/apple/AxoPhone/AxoPhoneUITests/test.outputs/tests.xcresult"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/axo-phone-visual.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
# The filter keeps this lane fast and produces stable visual states. Xcode stores the UI
# screenshots and per-test screen recordings in the XCResult bundle.
bazel test //apple/AxoPhone:AxoPhoneUITests \
  --ios_multi_cpus=sim_arm64 \
  --nocache_test_results \
  --test_filter='AxoPhoneUITests/testVisualSnapshotBlankChatLight,AxoPhoneUITests/testVisualSnapshotConversationDark,AxoPhoneUITests/testVisualSnapshotComposerWithKeyboard,AxoPhoneUITests/testVisualInteractionSequence' \
  --test_env=CREATE_XCRESULT_BUNDLE=1 \
  --test_arg=--xctestrun_attachment_lifetime=keepAlways \
  --test_output=errors

if [[ ! -d "$RESULT" ]]; then
  echo "Expected XCTest result bundle at $RESULT" >&2
  exit 1
fi

# Bazel makes test outputs read-only; xcresulttool updates its database while exporting.
ditto "$RESULT" "$WORK/tests.xcresult"
chmod -R u+w "$WORK/tests.xcresult"
xcrun xcresulttool export attachments \
  --path "$WORK/tests.xcresult" \
  --output-path "$WORK/attachments" >/dev/null
mkdir -p "$ARTIFACTS/screenshots" "$ARTIFACTS/videos"

python3 - "$WORK/attachments/manifest.json" "$WORK/attachments" "$ARTIFACTS" "$SNAPSHOTS" "$MODE" <<'PY'
import json
import pathlib
import shutil
import sys

manifest_path = pathlib.Path(sys.argv[1])
exported_dir = pathlib.Path(sys.argv[2])
artifacts_dir = pathlib.Path(sys.argv[3])
snapshots_dir = pathlib.Path(sys.argv[4])
mode = sys.argv[5]

names = (
    "blank-chat-light",
    "conversation-dark",
    "composer-keyboard-light",
    "interaction-composer-keyboard-dark",
)
found = set()
for test in json.loads(manifest_path.read_text()):
    for attachment in test.get("attachments", []):
        suggested = attachment.get("suggestedHumanReadableName", "")
        exported = exported_dir / attachment["exportedFileName"]
        for name in names:
            if suggested.startswith(name + "_") and suggested.endswith(".png"):
                destination = artifacts_dir / "screenshots" / f"{name}.png"
                shutil.copy2(exported, destination)
                found.add(name)
        if "testVisualInteractionSequence" in test.get("testIdentifier", "") and suggested.endswith(".mp4"):
            shutil.copy2(exported, artifacts_dir / "videos" / "interaction.mp4")

missing = set(names) - found
if missing:
    raise SystemExit("Missing screenshot attachment(s): " + ", ".join(sorted(missing)))
if not (artifacts_dir / "videos" / "interaction.mp4").is_file():
    raise SystemExit("Missing interaction video attachment")

if mode == "record":
    snapshots_dir.mkdir(parents=True, exist_ok=True)
    for name in names:
        shutil.copy2(artifacts_dir / "screenshots" / f"{name}.png", snapshots_dir / f"{name}.png")
    videos = snapshots_dir / "Videos"
    videos.mkdir(exist_ok=True)
    shutil.copy2(artifacts_dir / "videos" / "interaction.mp4", videos / "interaction.mp4")
    print(f"Recorded reviewed baselines in {snapshots_dir}")
PY

if [[ "$MODE" == "verify" ]]; then
  status=0
  for name in blank-chat-light conversation-dark composer-keyboard-light interaction-composer-keyboard-dark; do
    reference="$SNAPSHOTS/$name.png"
    current="$ARTIFACTS/screenshots/$name.png"
    if [[ ! -f "$reference" ]]; then
      echo "Missing reference snapshot: $reference (run $0 record after reviewing the screenshots)" >&2
      status=1
      continue
    fi
    if ! swift "$ROOT/scripts/compare-phone-snapshots.swift" "$reference" "$current"; then
      status=1
    fi
  done
  exit "$status"
fi
