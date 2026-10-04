#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for tool in python3 node qmllint shellcheck; do
    command -v "$tool" >/dev/null || { printf 'Missing check dependency: %s\n' "$tool" >&2; exit 1; }
done
python3 -m unittest -v test_bridge.py test_t3.py test_install.py
node test_queue.cjs
node test_activity.cjs
qmllint Service.qml shell.qml
shellcheck install.sh scripts/check.sh
if command -v omarchy >/dev/null; then omarchy plugin validate .; fi
if command -v ruff >/dev/null && ruff --version >/dev/null 2>&1; then
    ruff check .
    ruff format --check .
fi
printf 'Spool checks passed.\n'
