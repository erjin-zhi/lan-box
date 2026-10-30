#!/bin/zsh
# Real Sparkle smoke checks in disposable apps; never targets LanBox.app.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 Tests/run-updater-smoke.py "$@"
