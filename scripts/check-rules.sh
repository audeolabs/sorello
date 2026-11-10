#!/usr/bin/env bash
# Runs the lint in check-rules.py, after the lint's own regression cases.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
python3 "$here/check-rules.py" --self-test
python3 "$here/check-rules.py"
