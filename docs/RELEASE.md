# Spool 0.7.0 release preparation

This is a local release candidate. Publishing, a release tag, and hosted CI have not been performed. No remote is configured in this checkout.

## Reproduce the checks

Run `make check`, then `make dist`. The checks use isolated XDG directories for installation tests and do not restart the real shell. The source package uses an explicit file allowlist, stable archive timestamps, and normalized file modes. `dist/SHA256SUMS` identifies the exact archive.

Extract the archive into a clean directory and run `make check` there before distributing it. The package includes source, tests, documentation, original artwork, and all license notices. Personal runtime evidence and the original desktop screenshot are excluded. The documentation preview uses synthetic thread data.

## Verified locally

- T3 SQLite access is read-only, pending input is scoped to the latest run, and raw reasoning/prompts/tool outputs are excluded.
- Framed socket reads, size limits, operation allowlist, detail-timeout recovery, and sample deadlines have regression tests.
- Recency, pinning, history, completion dismissal, snooze expiry, next-run resume, and transient-state pruning have automated checks.
- Installer tests preserve previous files and shell settings, verify context-only configuration, reject invalid arguments, and version JavaScript imports.
- QML parsing, shell lint, and Omarchy plugin validation are included in the check command.
- Live checks on the development host covered image loading, mini/full views, persistence, and a single transparent Spool overlay. Earlier synthetic runtime checks covered attention navigation, history, snoozes, quiet filtering, and completion dismissal.

## Remaining qualification

- The Codex/ChatGPT desktop endpoint on this host currently times out. Mock transport tests pass; live desktop reconnection and event delivery are not release-qualified.
- A fresh install on another supported Omarchy host has not been checked.
- Pointer dragging, every menu action, and fullscreen transitions have not received a complete hands-on release pass.
- Provider status support is neutral through T3, but public progress availability varies by provider. There is no claim of live testing every provider.

The code and original artwork are AGPL-3.0-only. The bundled provider icons retain their separate MIT license. See `NOTICE.md` for attribution.
