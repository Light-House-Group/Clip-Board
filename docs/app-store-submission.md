# Mac App Store submission — Clip-Board

Everything needed to submit the **App Store edition** (`io.github.light-house-group.clipboard-appstore`,
sandboxed, no auto-paste). Build it from the `App-Store` branch with the
**`Clip Board (App Store)`** Xcode scheme.

---

## 1. Code readiness (done in this branch — verified)

| Item | State |
| :--- | :--- |
| App Sandbox enabled | ✅ `ENABLE_APP_SANDBOX = YES` (Release-AppStore) + `Clip Board-AppStore.entitlements` |
| Auto-paste removed | ✅ compiled out under `APPSTORE`; binary has 0 `AXIsProcessTrusted` refs |
| No network entitlements / no network code | ✅ entitlements `false`; `otool -L` = Apple frameworks only |
| Bundle ID | ✅ `io.github.light-house-group.clipboard-appstore` |
| App icon | ✅ full 10-size PNG set, 1024 has no alpha |
| Privacy manifest | ✅ `PrivacyInfo.xcprivacy` (no collection; UserDefaults reason `CA92.1`) |
| Export compliance | ✅ `ITSAppUsesNonExemptEncryption = NO` in Info.plist |
| Launch at Login | ✅ `SMAppService` (sandbox-safe) |
| Hardened runtime | ✅ on (accepted by the store) |
| Copyright string | ✅ `© 2026 Siddharth Sangwan` |
| Min macOS | ✅ 14.0 |
| Sandbox runtime (smoke test) | ✅ ad-hoc sandboxed launch: clipboard captured → AES-GCM encrypted → persisted to the container (`history.json.enc`, mode 0600); no sandbox denials, no crash; Keychain key created in-sandbox |

## 2. Apple-account prerequisites (you must do — outside the repo)

- [ ] **Confirm the signing Team** has App Store distribution. The project defaults to
      `PT666QK286` (your Developer ID team). If your paid App Store membership is a
      different team, change it in **Signing & Capabilities** for the App Store config.
- [ ] **Apple Distribution certificate + provisioning profile** — none exists yet.
      Xcode automatic signing creates both on first Archive. Nothing to do manually.
- [ ] **Decide the seller name.** Your account is the individual "Siddharth Sangwan",
      so the store will list it under that name. To list under **"Light House Group"**
      you need an **Organization** Apple Developer account (requires a D-U-N-S number).
- [ ] **Create the app record** in App Store Connect with the bundle ID above.

## 3. Archive & upload

```
Xcode → select the "Clip Board (App Store)" scheme
Product → Archive
Organizer → Distribute App → App Store Connect → Upload  (automatic signing)
```

## 4. App Store Connect listing — draft copy

> Edit to taste; these are starting points.

- **Name:** Clip-Board
- **Subtitle (≤30):** Private clipboard history
- **Category:** Primary: Productivity · Secondary: Utilities
- **Promotional text (≤170):** A clipboard history that stays on your Mac. Encrypted at rest, zero network code, no account, no tracking. Search, pin, and bring anything you copied back.
- **Keywords (≤100):** clipboard,history,manager,paste,copy,snippet,pin,privacy,encrypted,menu bar,productivity
- **Description:**
  ```
  Clip-Board remembers what you copy — text, images, and formatted snippets — so you
  can find and reuse it later, from a fast menu-bar panel.

  Privacy first, by construction:
  • Encrypted on disk. Every entry is sealed with AES-GCM-256 against a key in your
    Keychain that never leaves your Mac.
  • No network. The app contains no networking code — no account, no cloud, no
    telemetry, no ads.
  • Skips secrets. Items that apps mark transient/concealed (the convention password
    managers use) are never recorded.

  Features:
  • Searchable history with instant filtering
  • Pin the items you reuse often
  • Image and rich-text capture
  • Configurable history size
  • Lightweight menu-bar app — no Dock clutter

  Note: the App Store edition is sandboxed per Apple's requirements, so it copies a
  selected item to the clipboard for you to paste with ⌘V. (The direct download from
  our website adds one-keystroke paste-back.)
  ```
- **Support URL:** https://github.com/Light-House-Group/Clip-Board
- **Marketing URL (optional):** https://github.com/Light-House-Group/Clip-Board
- **Privacy Policy URL:** host `PRIVACY.md` and link it, e.g.
  `https://raw.githubusercontent.com/Light-House-Group/Clip-Board/App-Store/PRIVACY.md`
  (or a GitHub Pages URL).

## 5. App Privacy ("nutrition label")

Answer in App Store Connect → App Privacy:

- **Data collection:** _No, we do not collect data from this app._ → results in
  **"Data Not Collected"**, consistent with `PrivacyInfo.xcprivacy`.
- **Tracking:** No.

## 6. Export compliance

Pre-answered by `ITSAppUsesNonExemptEncryption = NO` (only standard AES protecting the
user's own data at rest — exempt). No CCATS/year-end self-classification report needed.

## 7. Screenshots (required)

macOS screenshots, one of these sizes (PNG/JPG, RGB, no transparency):
`1280×800`, `1440×900`, `2560×1600`, or `2880×1800`. Provide 1–10.

Suggested shots:
1. The history panel open over a real app, a few varied items.
2. Search in action (typed query filtering the list).
3. A pinned item + the right-click menu.
4. An image entry preview.

## 8. Age rating

All categories "None" → expected rating **4+**.

## 9. Review-risk notes (not blockers)

- A clipboard manager continuously reads `NSPasteboard.general`. On macOS 15.4+/26 the
  OS may surface clipboard-access notifications; this is expected behavior, not a bug.
- The per-item source-app icon chip uses LaunchServices lookups that may be limited in
  the sandbox; it degrades gracefully (no icon) and does not affect functionality.
