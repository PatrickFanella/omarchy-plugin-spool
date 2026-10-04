#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build a deterministic, allowlisted source release without personal runtime data."""

import gzip
import hashlib
import io
import json
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "manifest.json",
    "Service.qml",
    "TaskQueue.js",
    "ActivityStore.js",
    "bridge.py",
    "shell.qml",
    "install.sh",
    "README.md",
    "LICENSE",
    "NOTICE.md",
    "CHANGELOG.md",
    "Makefile",
    "pyproject.toml",
    "test_bridge.py",
    "test_t3.py",
    "test_install.py",
    "test_queue.cjs",
    "test_activity.cjs",
    "scripts/check.sh",
    "scripts/package.py",
    "docs/RELEASE.md",
    "docs/preview.png",
    "assets/spool.png",
    "assets/providers/LICENSE",
    "assets/providers/openai.svg",
    "assets/providers/anthropic.svg",
    "assets/providers/google.svg",
    "assets/providers/opencode.svg",
]


def main():
    manifest = json.loads((ROOT / "manifest.json").read_text())
    version = manifest["version"]
    prefix = f"spool-{version}"
    output = ROOT / "dist"
    output.mkdir(exist_ok=True)
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name in sorted(FILES):
            data = (ROOT / name).read_bytes()
            info = tarfile.TarInfo(f"{prefix}/{name}")
            info.size = len(data)
            info.mode = (
                0o755
                if name in {"install.sh", "scripts/check.sh", "scripts/package.py"}
                else 0o644
            )
            info.mtime = 0
            archive.addfile(info, io.BytesIO(data))
    target = output / f"{prefix}.tar.gz"
    with target.open("wb") as file:
        with gzip.GzipFile(filename="", mode="wb", fileobj=file, mtime=0) as compressed:
            compressed.write(payload.getvalue())
    checksum = hashlib.sha256(target.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{checksum}  {target.name}\n")
    print(f"{target.relative_to(ROOT)}\n{checksum}")


if __name__ == "__main__":
    main()
