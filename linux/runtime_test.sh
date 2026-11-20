#!/bin/sh
# Archive-only acceptance: no service registration, live socket or account access.
set -eu
exec /usr/bin/python3 "$(dirname "$0")/runtime_test.py" "$@"
