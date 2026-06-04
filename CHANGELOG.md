# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/).

## [1.3.0] — 2026-06-04

### Added

- **Mac App Store edition.** A second, sandboxed edition now builds from the same source under the `APPSTORE` compile flag and the `Clip Board (App Store)` scheme. Because the Mac App Store mandates the App Sandbox — which forbids the Accessibility API and keystroke synthesis — **auto-paste is compiled out** of this edition: history items are placed on the clipboard and you paste them yourself with ⌘V. Everything else (encryption at rest, transient-type skipping, rich-text capture, search, pinning) is identical. The two editions share one Apple Developer account but are signed with different certificate *types*: App Store with Apple Distribution, direct with Developer ID Application.

### Changed

- **Bundle identifier is now `io.github.light-house-group.clipboard`** (App Store edition: `io.github.light-house-group.clipboard-appstore`), replacing the previous personal-name identifier. **Existing users upgrading the direct build must re-grant Accessibility and re-enable Launch at Login** — macOS keys those off the bundle ID. Your clipboard history is preserved: it is keyed on the Keychain service `com.clipboard.manager`, not the bundle ID.
- **Releases are now Developer ID–signed, notarized, and stapled.** First launch of the direct build opens normally on a double-click — no more right-click → **Open** to clear Gatekeeper. Verify with `spctl -a -vvv "Clip Board.app"` (expect `source=Notarized Developer ID`) and `codesign -d --entitlements - "Clip Board.app"` (sandbox and network entitlements remain `false`).
- **`scripts/release.sh` now self-verifies and refuses to emit a broken artifact.** The Developer ID build is rejected unless it passes `codesign --strict`, carries a non-adhoc Team signature, and keeps the App Sandbox plus network entitlements off (the posture promised in [SECURITY.md](SECURITY.md)); a `--notarize` build must additionally pass Gatekeeper as Notarized Developer ID. The script auto-detects the signing identity and writes `Clip-Board.zip.sha256` for the Homebrew cask.

[1.3.0]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.3.0

## [1.2.5] — 2026-05-31

### Fixed

- **Keyboard navigation no longer bounces between 2–3 rows.** When you press ↓ or ↑, the scroll animation slides a new row under the (stationary) mouse cursor. SwiftUI then fires a hover event on that row, and the parent's hover handler was setting `selectedID = item.id` — overwriting the keyboard selection on every scroll tick. The visible symptom was the list refusing to advance past whichever row the cursor had been hovering over. Fix: mouse location is now anchored at each kb-nav event; the hover handler ignores the selection-stomp until the cursor has actually moved (>4 pt). Manual mouse hover still selects normally as soon as you move the cursor.
- **Hover preview no longer opens for short text (root cause fix).** The 1.2.4 widening of the slack threshold reduced the false-positive rate but didn't kill it: the dual-`GeometryReader` measurement could race on initial layout — if the unconstrained-height background landed first with a non-zero value while the constrained foreground was still 0, `isTruncated` briefly flipped true and the popover opened. Replaced the whole approach with a deterministic `NSAttributedString.boundingRect` measurement against the row's actual width, counting lines directly. No race, no slack heuristic.
- **Popover orphans on Clear and search.** `Clear` now also resets the preview state; if a search filter hides the currently-previewed item, the popover dismisses automatically instead of pointing at a stale or off-screen row.

### Added

- **Arrow keys now open the preview popover for the selected row.** When you navigate with ↓ / ↑, the popover for the newly selected row opens after a 250 ms settle so holding the arrow key doesn't flash a popover per scrolling row. The same `previewEligible` gate from hover applies — non-truncated text rows just get the selection highlight, image rows always preview, truncated text rows show the full content.

### Removed

- Dead `VisibleHeightKey` and `FullHeightKey` SwiftUI preference keys (only used by the prior dual-measurement path).

[1.2.5]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.5

## [1.2.4] — 2026-05-31

### Added

- **Original formatting is preserved on copy and paste.** When you copy styled text — from Mail, Notes, Pages, a browser, an IDE — Clip-Board now captures every standard text-class representation the source app published (`public.rtf`, `public.rtfd`, `public.html`, UTF-16 plain text) alongside the plain UTF-8 form. On paste from history, all representations are written back to the system pasteboard so the receiving app picks the highest-fidelity flavor it understands. Apps that only accept plain text still paste plain. Per-item rich payload is capped at 500 KB so a single styled copy can't bloat the encrypted store.
- **Right-click → History Size submenu.** Choose between **50 / 100 / 250 / 500 / 1000** items. The currently active preset is check-marked, and the title shows the current value. Lowering the cap immediately trims the oldest unpinned items; pinned items are always preserved regardless of cap. No "Unlimited" option — truly unbounded history breaks search latency, scroll perf, and per-save encryption time; the 5000-item internal ceiling on stored values is the hard backstop.

### Fixed

- **Hover preview no longer opens for text that's already fully visible.** The previous truncation check used a 1 pt slack and could mis-flag short text as truncated due to sub-pixel font-metric rounding (especially at 13 pt body, where the `lineLimit(2)` foreground and the unconstrained-height background can disagree by ~2 pt on a row that genuinely fits). Slack widened to 8 pt — half a line — so only genuine clipping triggers the popover. The `.popover` binding is also gated on `previewEligible` defensively, so any upstream state set on a non-eligible row is ignored. Image rows still preview on hover, unchanged.

### Changed

- History size limit (formerly a hardcoded `100`) is now a Preferences value; default stays `100`. Existing installs are unaffected.
- Storage schema gains an optional `richRepresentations: [String: Data]?` field on `ClipItem`. Backward-compatible — older items decode with the field absent and continue to paste plain text. No migration required.

[1.2.4]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.4

## [1.2.3] — 2026-05-31

### Fixed

- **Auto-paste now actually works.** Two compounding bugs were silently swallowing the synthesized ⌘V:
  1. The App Sandbox was enabled (since v1.0.0, via `ENABLE_APP_SANDBOX = YES` in the project). A sandboxed app on macOS 14+ cannot use `NSRunningApplication.activate()` to bring a foreign app to the foreground, so the previously-focused app never actually came forward and the keystroke landed on Clip-Board (or nowhere).
  2. Even unsandboxed, macOS 14+ requires the currently-active app to explicitly **yield activation** before another app can take focus. We now call `NSApp.yieldActivation(to:)` before activating the target, then post ⌘V once it's truly frontmost.

### Changed

- **App is no longer sandboxed.** Every shipping clipboard manager that does cross-app paste injection (Maccy, Paste, Alfred, Raycast) runs unsandboxed for exactly this reason — the sandbox is fundamentally incompatible with "activate any other app and synthesize a paste into it." See `SECURITY.md` for the full rationale and what hardening we *do* still apply (hardened runtime, no network linkage, AES-GCM at rest, Keychain key, file mode 0600 / dir 0700).
- Updated `NSRunningApplication.activate(options:)` (deprecated in macOS 14) → `activate()`.
- Bumped auto-paste activation budget from 500 ms → 600 ms (the yield handoff costs a frame or two).

### Security / hygiene

- Entitlements file now explicitly sets `com.apple.security.app-sandbox = false` with an inline comment explaining the trade-off, so reviewers can diff source against the signed binary and see the unsandboxed posture is intentional, not an oversight.

### Migration

- **Pre-1.2.3 history is automatically carried over.** Upgrading from 1.2.2 or earlier: on first launch, the old sandbox-container history (`~/Library/Containers/Siddharth.Sangwa.ClipBoard/Data/Library/Application Support/ClipboardManager/`) is copied to the new unsandboxed location (`~/Library/Application Support/ClipboardManager/`). The legacy container is left in place untouched, so downgrading still works.

[1.2.3]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.3

## [1.2.2] — 2026-05-30

### Fixed

- **Copy fidelity.** Leading/trailing whitespace on copied text is no longer stripped from the stored item. Previously, copying ` --flag` or ` :` would lose the leading space when pasted back from history; now items are stored byte-identical to what hit the clipboard. (Empty/whitespace-only copies are still skipped, and dedupe still applies — but on the raw value.)
- **Multi-monitor panel placement.** The floating panel now opens on the screen the cursor is on, not the screen with the key window. Triggering the hotkey from a secondary display no longer clamps the panel onto your primary display.
- **Thumbnail downscale moved off the main thread.** ImageIO downscale for newly captured screenshots now runs on the persistence I/O queue, eliminating a UI hitch when capturing large images.

### Changed

- **Launch-at-Login defaults to OFF.** Fresh installs no longer silently register themselves as a LaunchServices job; users opt in explicitly via the menu. Existing installs are unaffected (the stored preference takes precedence).
- **App display name is now plain "Clip Board"** (dropped the `📎` emoji from `CFBundleDisplayName` — it rendered inconsistently in Spotlight/mini-bar contexts).
- **Snapshot computation hoisted out of view body.** The filter/partition pass now runs only when its inputs (items, search text, visible limit) actually change, instead of on every hover/selection tick.

### Security / hygiene

- **Explicit `Clip Board.entitlements` checked in.** `com.apple.security.network.client` and `com.apple.security.network.server` are now explicitly `false` in a source-controlled file — reviewers can diff the signed binary's entitlements against the repo's source of truth with `codesign -d --entitlements - "Clip Board.app"`.
- **Logger privacy tightened.** `error.localizedDescription` values are now logged with `privacy: .private` so disk paths or framework-derived text don't appear in system logs as `.public`.
- **AppIconProvider cache capped** at 200 distinct bundle IDs (was unbounded).
- **Sandboxed path corrected in docs.** The README and source comments now reflect that history actually lives under the app's sandbox container, not `~/Library/Application Support`.
- **Pasteboard plaintext caveat** added to `SECURITY.md` (window between auto-paste and the next copy).

### Removed

- Dead `HotkeyManager.unregisterHotkey()` (never called).
- Unused `import Combine` in `UIViews.swift`.
- `ENABLE_TESTABILITY = YES` from Debug config (no test target consumes it).
- Inconsistent `MACOSX_DEPLOYMENT_TARGET = 26.0` at the project level (target was 14.0; project now matches).

[1.2.2]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.2

## [1.2.1] — 2026-05-30

### Changed

- **Default global shortcut is now ⌥V** (Option-V), changed from ⌃⌥⌘V. Existing installs keep whatever shortcut you've already configured — only fresh installs pick up the new default. Re-bind anytime via right-click → **Set Shortcut…**.
- **Panel corners are now symmetric.** The drop shadow was offset downward, which made the bottom corners read rounder than the top; the glow is now near-centered and the glass material uses the continuous "squircle" corner curve, so all four corners match. Top padding tightened.

[1.2.1]: https://github.com/Light-House-Group/Clip-Board/releases/tag/v1.2.1

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
