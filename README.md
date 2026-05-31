# Clip-Board

> Privacy-first clipboard history for macOS. Encrypted on disk, zero network code in the binary, fully auditable.

[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)](https://www.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![At-rest: AES-GCM 256](https://img.shields.io/badge/At--rest-AES--GCM%20256-brightgreen.svg)](#security-posture)
[![Latest release](https://img.shields.io/github/v/release/Light-House-Group/Clip-Board?label=release)](https://github.com/Light-House-Group/Clip-Board/releases/latest)

A native menu-bar app that remembers what you copy — text, images, formatted snippets — and pastes any of it back into the previously focused app with one keystroke or one click. macOS 14+, ~450 KB binary, no dependencies outside Apple-shipped frameworks.

---

## Why

Mainstream clipboard managers keep history in plaintext on disk, sync it to a vendor cloud, or both. That's fine right up until the day you copy a 2FA code through it, or paste a Slack DM you shouldn't have. Clip-Board's posture is the opposite of mainstream:

- **At-rest encryption.** Every entry — including images — sealed with AES-GCM-256 against a key in your Keychain (`WhenUnlockedThisDeviceOnly`, non-syncable).
- **No network.** The binary doesn't link `URLSession`, `Network.framework`, or any third-party SDK. You can prove it: `otool -L` shows only Apple system frameworks.
- **No telemetry, no account, no cloud, no auto-update beacon.** The product is one signed `.app`.
- **Small and auditable.** ~2,500 lines of Swift across three files; the security boundary fits on one screen.

---

## Install

### Homebrew

```bash
brew install --cask light-house-group/taps/clip-board
```

To upgrade later:

```bash
brew upgrade --cask clip-board
```

### Direct download

Grab `Clip-Board.zip` from the [latest release](https://github.com/Light-House-Group/Clip-Board/releases/latest), unzip, drag `Clip Board.app` into `/Applications`.

The release zip is **ad-hoc signed**, so the first launch trips Gatekeeper. Right-click the app → **Open** → **Open** to bypass once. Subsequent launches are silent. (Notarized builds are a single env-var + flag away — see [Build from source](#build-from-source).)

---

## First run

1. The app lives in your menu bar. No Dock icon, no main window. Look for the clipboard glyph at the top of the screen.
2. **Left-click** the icon (or press **⌥V**) to open the panel.
3. The first paste-back attempt will prompt for **Accessibility** in System Settings → Privacy & Security. Required to synthesize ⌘V into the previously focused app. Skip it and items still copy to the system clipboard; you just paste manually.
4. **Right-click** the icon for: shortcut config, launch-at-login, history-size cap, quit.

---

## Usage

| Action | How |
| :--- | :--- |
| Show / hide panel | Click menu-bar icon, or press the configured hotkey (default **⌥V**) |
| Copy + auto-paste back | Click row, or press **↩** on the selected row |
| Copy only (no paste) | Right-click row → Copy |
| Preview full content | Hover a truncated row / image for 1 s, or navigate with **↑ ↓** |
| Pin / unpin | Click pin icon, or right-click → Pin |
| Multi-delete | Right-click → Select → click rows → **Delete N** |
| Search | Type in the search field (180 ms debounce) |
| Clear unpinned | Trash button (confirms) |
| Clear all incl. pinned | **⌥**-click trash button (confirms) |
| Dismiss preview / close panel | **⎋** |
| Change shortcut | Right-click menu → Set Shortcut… |
| Set history size | Right-click menu → History Size → 50 / 100 / 250 / 500 / 1000 |

Pinned items are kept regardless of the history-size cap.

---

## What gets stored, and where

- **Path**: `~/Library/Application Support/ClipboardManager/`
  - `history.json.enc` — single AES-GCM-sealed JSON blob. File mode `0600`, directory mode `0700`, atomic writes (no partial-file exposure on crash).
  - `images/<uuid>.imgenc` — one encrypted file per image. Images are *not* inlined into the history JSON, which keeps text-only saves cheap.
- **Key**: in your Keychain at `service: com.clipboard.manager, account: com.clipboard.manager.symmetrickey`. Marked `kSecAttrSynchronizable = false` — never propagates to iCloud Keychain. Delete the entry → existing history becomes permanently unrecoverable. By design: no escrow, no second copy.
- **Schema**: versioned; new optional fields decode cleanly against older histories. A failed decrypt quarantines the file to `history.broken-<timestamp>` and starts fresh — corruption is moved aside, never silently dropped.
- **Per-item caps**: 100,000 characters per text entry; 25 MB per image; 500 KB per item for the additional rich-text representations (RTF, RTFD, HTML, UTF-16) captured alongside plain text so styled paste preserves formatting.
- **What we deliberately don't capture**: pasteboard items written with `org.nspasteboard.TransientType`, `ConcealedType`, or `AutoGeneratedType` — the convention password managers use. Those are silently skipped, never reach disk.

---

## Security posture

### Threat model

| Defended against | How |
| :--- | :--- |
| Disk seizure, stolen backup, unsupervised laptop | AES-GCM-256 encryption of the on-disk store with a Keychain-bound key |
| Cross-device leakage | Key is non-syncable (`kSecAttrSynchronizable = false`); never propagates via iCloud Keychain |
| Capture of sensitive pasteboard items | Honors `org.nspasteboard.*` transient / concealed / auto-generated markers; skipped, never persisted |
| Silent data corruption | Failed decrypts quarantine the file with a timestamp; nothing is destroyed without trace |

### Not defended against

- An attacker with your user privileges who reads the running process's memory. Fundamental to any "give me back what I copied" tool.
- Loss of the Keychain entry. By design — no recovery, no escrow.
- Another local user with root.
- The pasteboard window itself: between auto-paste and your next copy, the most recent item lives in plaintext on `NSPasteboard.general` where any concurrent process can see it. Intrinsic to "paste anything into any app," not specific to Clip-Board.

### Sandbox

**Clip-Board is intentionally not sandboxed.** The macOS App Sandbox blocks `NSRunningApplication.activate()` on a foreign app, which silently breaks the auto-paste flow. Maccy, Paste, Alfred, and Raycast all run unsandboxed for the same reason. The hardening that *is* applied:

- Hardened runtime ON (`ENABLE_HARDENED_RUNTIME = YES`).
- Network entitlements explicitly `false` in the checked-in [`Clip Board.entitlements`](Clip%20Board/Clip%20Board.entitlements) — reviewers diff source against signed binary.
- No `URLSession`, `Network.framework`, or third-party SDK linked.

Full rationale and the migration story (pre-1.2.3 sandboxed → 1.2.3+ unsandboxed) is in [SECURITY.md](SECURITY.md#sandbox--entitlements).

### Verify a downloaded build

```bash
# Linked libraries — Apple system frameworks only.
otool -L "Clip Board.app/Contents/MacOS/Clip Board"

# Entitlements — should match the checked-in file byte-for-byte:
#   app-sandbox=false, network.client=false, network.server=false.
codesign -d --entitlements - "Clip Board.app"
```

The entitlements file [`Clip Board/Clip Board.entitlements`](Clip%20Board/Clip%20Board.entitlements) is the source of truth a reviewer can diff against the signed binary.

---

## Build from source

Requires macOS 14+ and Xcode 15 or newer (built on Xcode 26).

```bash
git clone https://github.com/Light-House-Group/Clip-Board.git
cd Clip-Board
open "Clip Board.xcodeproj"        # Xcode → Product → Run
```

Or from the command line, with the included release script:

```bash
./scripts/release.sh                                                # ad-hoc signed
DEVELOPER_ID="Developer ID Application: ..." ./scripts/release.sh   # Developer ID signed
NOTARY_PROFILE=clip-board ./scripts/release.sh --notarize           # signed + notarized + stapled
```

The script writes the final `.app` and `Clip-Board.zip` under `release/`.

---

## Project layout

```
Clip Board/
  AppAndCrypto.swift     Preferences · KeyManager · AppPaths · ImageStore ·
                         PersistenceManager · AppDelegate · @main
  History.swift          ClipItem · ItemsViewModel · ClipboardWatcher ·
                         HotkeyManager · AutoPaster
  UIViews.swift          SwiftUI views · NSPanel / NSStatusItem bridges ·
                         HotkeyRecorder
  Clip Board.entitlements
scripts/
  release.sh             Archive → sign → optional notarize → zip
```

Three Swift files, ~2,500 lines total. Boundaries are by concern (crypto / persistence, model + system bridges, UI), not by SwiftUI view tree. The whole security surface fits in one file.

---

## Contributing

PRs welcome — keep them small and focused. For anything that shifts the threat model (storage format, encryption, IPC, a new entitlement), open an issue first and describe the change before writing code.

Conventions:

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Doc-comment new public types and any non-obvious decisions.
- `os.Logger` for diagnostics, never `print`. Error strings derived from file paths or framework messages use `privacy: .private`.
- macOS-native UI; avoid heavy custom styling.

Security issues — don't open a public issue. See [SECURITY.md](SECURITY.md).

---

## License

MIT — see [LICENSE](LICENSE).

Built by [@SNGWN](https://github.com/SNGWN).
