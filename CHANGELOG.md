# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/).

## [1.2.0] — 2026-05-29

### Added

- **Image & screenshot history.** Any image placed on the clipboard (screenshots copied with `⌃` modifiers, images copied from browsers, etc.) is captured into history. Images are stored as **individual AES-GCM-encrypted files** (`ClipboardManager/images/<id>.imgenc`) — never embedded in the history JSON — so text-copy saves stay cheap and the encrypted-at-rest guarantee extends to images. Rows show the image shrunk to the panel width (aspect preserved, height capped); hovering for 1 s opens a full-resolution, scrollable preview. Clicking an image row copies it back and auto-pastes it.
- **Source-app attribution.** Each entry records the app it was copied from; the row shows that app's icon and name next to the timestamp.

### Changed

- **Full value shown whenever a row is truncated.** Replaced the character-count heuristic with real, measured truncation detection — any text row that's visually clipped (`…`) is now hoverable for the full value, not just long ones.
- **Fixed the trailing gap in the text preview popover.** It now sizes to the measured content height instead of an over-estimate.

### Security / hygiene

- History schema bumped to v2 (backward compatible: v1 files load unchanged; new fields are optional).
- Orphaned image files (from a crash or external history wipe) are pruned on launch.
- Self-originated pasteboard writes (auto-paste/copy) are now suppressed from the watcher, preventing self-echo and preserving original source-app attribution.

[1.2.0]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.0

## [1.1.0] — 2026-05-29

### Added

- **Multi-select mode** — right-click any row → *Select* enters multi-select. Click anywhere on a row to toggle its selection (no leading checkboxes); a stronger accent tint plus a trailing checkmark indicates selected rows. The Clear button morphs into Cancel + **Delete N**. Esc exits the mode.
- **Confirmation dialog on Clear** — system-style sheet asks before destroying history; Return triggers the destructive action, Esc cancels. ⌥-click variant uses a stronger warning ("Clear all items, including pinned?").
- **Attribution footer** — "Clip-Board by Siddharth Sangwan" with a small clipboard glyph, centered at the bottom of the panel.
- **Homebrew tap** — install via `brew install --cask light-house-group/taps/clip-board`.

### Changed

- **Header removed.** The redundant "Clipboard" label and icon are gone; top padding adjusted (20 pt) to keep the search bar off the rounded edge.
- **Per-row trailing actions simplified.** Removed the per-row copy glyph (redundant with row tap which auto-pastes and with right-click → Copy). Pin glyph upsized from 11 pt to 14 pt for stronger affordance.
- **Glass preview popover.** The full-text hover popover now uses `NSVisualEffectView` with the system popover material for a Liquid-Glass-style translucent surface that adapts to the macOS Tahoe aesthetic.
- **Sharper Escape priority** in the panel: preview → exit-select → clear-search → close-panel.

[1.1.0]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.1.0

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
