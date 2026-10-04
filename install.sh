#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
case "${1:-}" in
    ""|--restart-shell) ;;
    --help|-h) printf 'Usage: %s [--restart-shell]\n' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
esac
if (( $# > 1 )); then printf 'Expected at most one option.\n' >&2; exit 2; fi
command -v python3 >/dev/null
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/onnwee.spool"
backup_dir="${XDG_STATE_HOME:-$HOME/.local/state}/spool/install-$(date +%Y%m%d-%H%M%S)-$$"
command -v omarchy >/dev/null
command -v omarchy-shell >/dev/null
omarchy plugin validate "$source_dir"
mkdir -p "$backup_dir" "$(dirname -- "$plugin_dir")"
config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
if [[ -f "$config" ]]; then cp -a -- "$config" "$backup_dir/shell.json"; fi
if [[ -e "$plugin_dir" ]]; then cp -a -- "$plugin_dir" "$backup_dir/plugin"; fi
mkdir -p "$plugin_dir/assets"
cp -- "$source_dir/bridge.py" "$plugin_dir/"
cp -- "$source_dir/TaskQueue.js" "$plugin_dir/"
cp -- "$source_dir/ActivityStore.js" "$plugin_dir/"
# A new component URL avoids retaining an older QML component in the live shell.
python3 - "$source_dir" "$plugin_dir" <<'PYINSTALL'
from pathlib import Path
import hashlib, json, sys
source, target = map(Path, sys.argv[1:])
qml = (source / "Service.qml").read_bytes()
for name in ("TaskQueue", "ActivityStore"):
    content = (source / (name + ".js")).read_bytes()
    library = name + hashlib.sha256(content).hexdigest()[:12].upper() + ".js"
    (target / library).write_bytes(content)
    qml = qml.replace(('"' + name + '.js"').encode(), ('"' + library + '"').encode())
entry = "Service" + hashlib.sha256(qml).hexdigest()[:12].upper() + ".qml"
(target / entry).write_bytes(qml)
manifest = json.loads((source / "manifest.json").read_text())
manifest["entryPoints"]["service"] = entry
(target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PYINSTALL
cp -- "$source_dir/assets/spool.png" "$plugin_dir/assets/"
cp -r -- "$source_dir/assets/providers" "$plugin_dir/assets/"
cp -- "$source_dir/LICENSE" "$source_dir/NOTICE.md" "$plugin_dir/"
omarchy-shell shell rescanPlugins
if [[ "${1:-}" == "--restart-shell" ]]; then
    omarchy restart shell
fi
# Registry discovery completes asynchronously.
for attempt in {1..20}; do
    if omarchy plugin enable onnwee.spool; then
        if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
            settings_json=$(python3 -c 'import json,os; print(json.dumps({"originThread":os.environ["CODEX_THREAD_ID"]}))')
            configured=false
            for configure_attempt in {1..20}; do
                if omarchy-shell spool configure "$settings_json"; then configured=true; break; fi
                if (( configure_attempt < 20 )); then sleep 0.25; fi
            done
            if [[ "$configured" != true ]]; then
                printf 'Spool activity configuration failed. Backup: %s\n' "$backup_dir" >&2
                exit 1
            fi
        fi
        printf 'Spool installed. Backup: %s\n' "$backup_dir"
        exit 0
    fi
    if (( attempt < 20 )); then sleep 0.25; fi
done
printf 'Plugin files copied, but enable failed. Backup: %s\n' "$backup_dir" >&2
exit 1
