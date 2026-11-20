#!/bin/sh
set -eu
exec /usr/bin/python3 "$(dirname "$0")/build_deb_test.py"
