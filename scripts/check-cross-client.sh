#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Never close another frontend or touch the operator's disabled production service.
open_count="$(xcrun swift -e 'import AppKit; print(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "dev.leostera.axo.mac" }.count)')"
if [[ "$open_count" != 0 ]]; then
  echo "Refusing cross-client UI acceptance while another Axo frontend is open." >&2
  exit 1
fi
codesign --verify --deep --strict dist/Axo.app
npm --prefix protocol run build
npm --prefix protocol run schema:check
cd sites/api.axo.leostera.dev
exec node --import tsx scripts/cross-client-fixture.ts
