# Privacy Policy — Clip-Board

_Last updated: 2026-06-04_

Clip-Board is a clipboard-history utility for macOS. This policy describes exactly
what the app does with your data. It is short because the app does very little.

## The short version

**Clip-Board collects nothing, sends nothing, and has no servers.** There is no
account, no analytics, no telemetry, no advertising, no tracking, and no network
code in the binary. Everything the app stores stays on your Mac.

## What the app stores, and where

Clip-Board keeps a local history of what you copy (text, images, and the rich-text
formatting that accompanies styled text) so you can paste it again later.

- The history is stored **only on your device**, encrypted at rest with
  **AES-GCM-256**. The encryption key lives in your **macOS Keychain**, is marked
  non-syncable, and never leaves the device.
- In the **Mac App Store edition**, the history lives inside the app's sandbox
  container. In the direct (Developer ID) edition it lives under
  `~/Library/Application Support/ClipboardManager/`.
- Clip-Board deliberately **does not capture** pasteboard items that apps mark as
  transient, concealed, or auto-generated (the convention password managers use).

You can clear your history at any time from within the app. Deleting the app, or
deleting its Keychain key, makes any remaining encrypted history permanently
unrecoverable — there is no backup or escrow.

## Data sharing and collection

- **No data is collected** by the developer.
- **No data is shared** with third parties.
- **No data is transmitted off the device.** The app links only Apple system
  frameworks and contains no networking code. You can verify this yourself:
  `otool -L "Clip Board.app/Contents/MacOS/Clip Board"` lists only Apple frameworks.

## Permissions

- The **Mac App Store edition** is sandboxed and requests no special permissions.
- The **direct edition** can optionally request macOS **Accessibility** permission,
  used only to paste a selected item back into your previously focused app. This is
  a local OS permission; it involves no data collection and is never sent anywhere.

## Children

Clip-Board is a general-purpose utility and is not directed at children. It collects
no personal information from anyone.

## Changes

If this policy changes, the updated version will be published at this URL with a new
"Last updated" date.

## Contact

Questions about privacy: open an issue at
<https://github.com/Light-House-Group/Clip-Board> or use the contact method listed
on the App Store product page.
