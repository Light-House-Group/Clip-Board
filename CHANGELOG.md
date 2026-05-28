# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-05-29

First public release.

### Added

- AES-GCM-256 encrypted history at rest, key in Keychain (`WhenUnlockedThisDeviceOnly`, non-syncable)
- Schema-versioned storage with quarantine on corrupt/undecryptable file (`history.broken-<ts>`)
- Configurable global hotkey (default ⌃⌥⌘V) with curated conflict catalog (warns when binding to ⌘C, ⌘V, ⌘Space, ⌘⇧3, etc.)
- Menu-bar app (no Dock icon); left-click opens history panel, right-click opens menu
- Right-click menu: Set Shortcut…, Launch at Login (toggle), Enable Auto-Paste… (shown when AX missing), Quit
- Auto-paste — synthesizes ⌘V into the previously focused app after activation polling
- Pinned items + 100-item rolling window for unpinned
- Search with 180 ms debounce, lazy list rendering
- Multi-line text preserved; long items show a smart, scrollable, text-selectable popover after 1 s hover
- Per-item size cap (100 K chars) so a single huge copy doesn't bloat the encrypted store
- Transient/concealed pasteboard markers honored (password-manager safety)
- `os.Logger` diagnostics under subsystem `com.clipboard.manager`
- Release script (`scripts/release.sh`) supporting ad-hoc, Developer ID, and notarized builds

### Notes

- macOS 14+ only
- Ad-hoc-signed release zip; users right-click → Open the first time, or build from source with their own Developer ID

[1.0.0]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.0.0
