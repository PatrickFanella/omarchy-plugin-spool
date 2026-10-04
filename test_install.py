# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise installation in isolated XDG roots with mocked Omarchy commands."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / "source"
        self.source.mkdir()
        for name in [
            "install.sh",
            "manifest.json",
            "Service.qml",
            "TaskQueue.js",
            "ActivityStore.js",
            "bridge.py",
            "LICENSE",
            "NOTICE.md",
        ]:
            shutil.copy2(ROOT / name, self.source / name)
        shutil.copytree(ROOT / "assets", self.source / "assets")
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()
        (bin_dir / "python3").symlink_to(sys.executable)
        stub = """#!/usr/bin/env python3
import json, os, pathlib, sys
name=pathlib.Path(sys.argv[0]).name
with open(os.environ["SPOOL_TEST_LOG"],"a") as file:
    file.write(json.dumps([name,sys.argv[1:]])+"\\n")
if name=="omarchy" and sys.argv[1:3]==["plugin","validate"]:
    root=pathlib.Path(sys.argv[3])
    assert (root/"Service.qml").exists() and (root/"assets/spool.png").exists()
"""
        for name in ["omarchy", "omarchy-shell"]:
            path = bin_dir / name
            path.write_text(stub)
            path.chmod(0o755)
        self.config = self.directory / "config"
        self.state = self.directory / "state"
        self.env = dict(
            os.environ,
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
            XDG_CONFIG_HOME=str(self.config),
            XDG_STATE_HOME=str(self.state),
            CODEX_THREAD_ID="release-test-context",
            SPOOL_TEST_LOG=str(self.directory / "calls.jsonl"),
        )
        self.plugin = self.config / "omarchy/plugins/onnwee.spool"

    def install(self, *args):
        return subprocess.run(
            ["bash", str(self.source / "install.sh"), *args],
            env=self.env,
            text=True,
            capture_output=True,
            check=True,
        )

    def test_install_backups_and_versioned_imports_preserve_preferences(self):
        self.plugin.mkdir(parents=True)
        (self.plugin / "previous.txt").write_text("existing installation")
        config = self.config / "omarchy/shell.json"
        original = '{"plugins":[{"id":"other.plugin"},{"id":"onnwee.spool","autoActivity":false}]}'
        config.write_text(original)
        self.install()
        manifest = json.loads((self.plugin / "manifest.json").read_text())
        first_entry = manifest["entryPoints"]["service"]
        qml = (self.plugin / first_entry).read_text()
        self.assertNotIn('"TaskQueue.js"', qml)
        self.assertNotIn('"ActivityStore.js"', qml)
        self.assertEqual(config.read_text(), original)
        backups = list((self.state / "spool").glob("install-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(
            (backups[0] / "plugin/previous.txt").read_text(), "existing installation"
        )
        self.assertEqual((backups[0] / "shell.json").read_text(), original)
        calls = [
            json.loads(line)
            for line in (self.directory / "calls.jsonl").read_text().splitlines()
        ]
        configure = next(
            args
            for name, args in calls
            if name == "omarchy-shell" and args[:2] == ["spool", "configure"]
        )
        self.assertEqual(
            json.loads(configure[2]), {"originThread": "release-test-context"}
        )
        self.assertEqual(
            (self.plugin / "LICENSE").read_bytes(), (ROOT / "LICENSE").read_bytes()
        )
        library = self.source / "TaskQueue.js"
        library.write_text(library.read_text() + "\n// changed library\n")
        self.install()
        updated = json.loads((self.plugin / "manifest.json").read_text())[
            "entryPoints"
        ]["service"]
        self.assertNotEqual(first_entry, updated)

    def test_invalid_arguments_do_not_change_user_files(self):
        result = subprocess.run(
            ["bash", str(self.source / "install.sh"), "--invalid"],
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.config.exists())
        self.assertFalse(self.state.exists())
