### Repository URL

https://github.com/PatrickFanella/omarchy-plugin-spool

### Category

Developer Tools

### Tags

ai, hyprland, quickshell

### Suggest a missing tag

_No response_

### Maintainer notes

Spool is an animated cassette companion with a scrollable activity tray for local T3 Code sessions across providers and an experimental Codex desktop/ChatGPT adapter. Plugin ID: `onnwee.spool`. Version: `0.7.0`.

Install with `omarchy plugin add https://github.com/PatrickFanella/omarchy-plugin-spool.git --enable`. No manual setup is required for the default T3 source when T3 Code is running locally. Desktop tracking is optional and selected from Spool's menu.

Runtime dependencies: Omarchy Quattro's Quickshell plugin API, compatible Quickshell (developed with 0.3.1), Hyprland, and Python 3.11+. T3 activity requires a running local T3 Code installation; desktop activity requires a running Codex desktop app exposing its local task-tool endpoint. No third-party Python packages are required at runtime.

The bridge reads T3's SQLite database in read-only transactions and uses the desktop app's local Unix socket. It reads activity and can bring the selected app forward; it sends no messages and approves no actions. Raw reasoning, prompts, and tool output are excluded. T3 clicks focus its existing desktop window without thread navigation or browser pairing.

Code and original Spool artwork: AGPL-3.0-only. Provider icons: MIT, with attribution in NOTICE.md and assets/providers/LICENSE. The root preview uses synthetic session data.

The standard Omarchy install path does not run install.sh. The optional manual installer backs up existing plugin files and shell.json, then installs and enables Spool. Preferences are preserved; shell restart occurs only with --restart-shell. Removal instructions and backup locations are in the README.

Local adapter/UI/installer tests and lint pass. Codex session listing and reconnection have been checked; a new native Codex turn, full event delivery, every provider, and a fresh install on a second host remain unqualified.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
