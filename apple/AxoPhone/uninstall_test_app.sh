#!/bin/bash
# Runs before the UI tests, on the simulator they use ($SIMULATOR_UDID, set by the runner).
#
# Removes the phone app, so the tests run the build they were given. Installing a build with the
# same version and build number as the one already on the simulator can leave the old app in
# place, and then the tests silently run stale code.
set -euo pipefail

bundle_id="@BUNDLE_ID@"
if [[ -z "${SIMULATOR_UDID:-}" ]]; then
  echo "uninstall_test_app: no SIMULATOR_UDID from the test runner" >&2
  exit 1
fi
# Not installed is fine: there is nothing stale to run.
xcrun simctl uninstall "$SIMULATOR_UDID" "$bundle_id" 2>/dev/null || true
echo "uninstall_test_app: removed $bundle_id from $SIMULATOR_UDID, if it was there"
