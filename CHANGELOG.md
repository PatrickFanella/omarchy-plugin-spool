# Changelog

## 0.7.0 — release candidate

### Added

- Local T3 activity across providers, alongside the experimental Codex desktop/ChatGPT adapter.
- Five-line scrollable progress cards, current-run comment history, provider logos, and source details.
- Progress recency ordering, persistent thread pins, attention navigation, recent completions, and snoozes.
- Independent motion pause, attention-only filtering, and a persistent 38-pixel mini mode.
- AGPLv3 licensing for code and original artwork; MIT attribution for bundled provider icons.
- Repeatable release checks, isolated installer tests, and reproducible source packages with checksums.

### Fixed

- Bring the existing T3 desktop window forward without opening a browser or requesting pairing.
- Preserve selection and text scroll position through unchanged polls.
- Use ShellRoot for standalone previews to avoid blank floating windows.
- Keep desktop run identity stable through completion when turn IDs are absent.
- Retain fetched desktop status when a detail read times out, and bound total desktop sampling time.
- Prune stale UI state and validate saved snoozes.
- Open selected recent threads when clicking the pet.
- Version JavaScript imports as well as QML; preserve disabled activity tracking during updates.

### Compatibility

The activity adapters use local app interfaces rather than a stable public event API. The development host's desktop endpoint currently times out; live T3 tracking is verified. Exact T3 thread navigation is unavailable. Remote T3, standalone CLI/IDE sessions, and ChatGPT browser tabs are outside this release.
