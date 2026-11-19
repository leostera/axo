#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$1"
