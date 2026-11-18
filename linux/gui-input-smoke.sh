#!/bin/bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
export AXO_LINUX_FIXTURE_SCRIPT="$here/gui-input-fixture.py"
export AXO_LINUX_TEST_FILTER=real_gui_form_uses_exact_fields_without_focus_or_secret_readback
exec "$here/computer-smoke.sh" "$@"
