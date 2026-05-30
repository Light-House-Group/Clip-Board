import SwiftUI
import AppKit
import Foundation
import Combine
import Carbon
import ApplicationServices
import os

// MARK: - Data Model

/// Kind of a stored clipboard entry. Optional on `ClipItem` for backward compatibility
/// with v1 files that predate images — a missing value decodes to `nil` → treated as text.
nonisolated enum ClipKind: String, Codable {
    case text
    case image
}

/// `nonisolated` so its Codable conformance is callable from the persistence IO queue.
/// Without it, the project's `-default-isolation=MainActor` flag would bind the
/// conformance to the main actor and emit a Swift 6 forward-compat warning.
///
/// All fields added after v1.0 are optional so older encrypted histories decode cleanly
/// (synthesized `Decodable` maps a missing key for an `Optional` property to `nil`).
nonisolated struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    /// For text items: the content. For image items: a human label (e.g. "Image 1920×1080").
    let text: String
    var date: Date
    var pinned: Bool = false

    // Added in 1.2 —
    var kind: ClipKind? = nil
    var imageFileName: String? = nil   // file under ImageStore (encrypted PNG)
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var imageHash: String? = nil       // SHA-256 hex of PNG bytes, for image dedupe
    var sourceBundleID: String? = nil  // bundle id of the app the copy came from
    var sourceAppName: String? = nil   // localized name of that app

    var resolvedKind: ClipKind { kind ?? .text }
    var isImage: Bool { resolvedKind == .image }
}

/// What the clipboard watcher captured on a single pasteboard change.
nonisolated enum CapturedItem {
    case text(String, sourceBundleID: String?, sourceAppName: String?)
    case image(png: Data, width: Int, height: Int, sourceBundleID: String?, sourceAppName: String?)
}

// MARK: - ViewModel

final class ItemsViewModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    private let limit = 100
    /// Per-item character cap for TEXT items. Beyond this the stored text is truncated with
    /// a marker so a single multi-megabyte copy can't bloat the encrypted history file.
    private static let maxItemChars = 100_000
    private static let truncationMarker = "\n\n[…truncated by Clip-Board]"
    /// Hard ceiling on a single stored image (bytes of PNG). Larger images are dropped.
    private static let maxImageBytes = 25_000_000

    private let saveSubject = PassthroughSubject<Void, Never>()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        items = PersistenceManager.shared.load()

        // Delete any orphaned image files left by a crash or external history wipe.
        ImageStore.shared.pruneOrphans(referenced: Set(items.compactMap { $0.imageFileName }))

        // Debounce on main so the items read happens on the same queue that mutates it.
        // PersistenceManager.save then dispatches encode/encrypt/write to its own ioQueue.
        saveSubject
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                PersistenceManager.shared.save(items: self.items)
            }
            .store(in: &cancellables)
    }

    private func scheduleSave() { saveSubject.send(()) }

    /// Adds a text item; preserves internal whitespace/newlines, only trims leading/trailing,
    /// and truncates beyond `maxItemChars`. Dedupes by exact equality of the stored text
    /// (an existing match moves to the top and refreshes its date + source app).
    func addText(_ text: String, sourceBundleID: String? = nil, sourceAppName: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let stored: String
        if trimmed.count > Self.maxItemChars {
            stored = String(trimmed.prefix(Self.maxItemChars)) + Self.truncationMarker
        } else {
            stored = trimmed
        }

        if let existingIndex = items.firstIndex(where: { !$0.isImage && $0.text == stored }) {
            var existing = items.remove(at: existingIndex)
            existing.date = Date()
            existing.sourceBundleID = sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = sourceAppName ?? existing.sourceAppName
            items.insert(existing, at: 0)
            scheduleSave()
            return
        }

        let newItem = ClipItem(
            id: UUID(), text: stored, date: Date(), pinned: false,
            kind: .text,
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName
        )
        items.insert(newItem, at: 0)
        trimIfNeeded()
        scheduleSave()
    }

    /// Adds an image item. Encrypts the PNG to its own file, dedupes by content hash
    /// (an identical image already present moves to the top).
    func addImage(png: Data, width: Int, height: Int,
                  sourceBundleID: String? = nil, sourceAppName: String? = nil) {
        guard png.count <= Self.maxImageBytes else {
            Log.clipboard.info("Skipped image: \(png.count) bytes exceeds cap.")
            return
        }
        let hash = ImageStore.shared.sha256Hex(png)

        if let existingIndex = items.firstIndex(where: { $0.imageHash == hash }) {
            var existing = items.remove(at: existingIndex)
            existing.date = Date()
            existing.sourceBundleID = sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = sourceAppName ?? existing.sourceAppName
            items.insert(existing, at: 0)
            scheduleSave()
            return
        }

        let id = UUID()
        let fileName = "\(id.uuidString).imgenc"
        ImageStore.shared.save(png: png, fileName: fileName)

        let label = "Image \(width)×\(height)"
        let newItem = ClipItem(
            id: id, text: label, date: Date(), pinned: false,
            kind: .image,
            imageFileName: fileName, imageWidth: width, imageHeight: height, imageHash: hash,
            sourceBundleID: sourceBundleID, sourceAppName: sourceAppName
        )
        items.insert(newItem, at: 0)
        trimIfNeeded()
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trimIfNeeded()
        scheduleSave()
    }

    func deleteItem(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        deleteImageFiles(for: [items[idx]])
        items.remove(at: idx)
        scheduleSave()
    }

    func clearHistory(removePinned: Bool = false) {
        if removePinned {
            deleteImageFiles(for: items)
            items.removeAll()
        } else {
            let removed = items.filter { !$0.pinned }
            deleteImageFiles(for: removed)
            items.removeAll(where: { !$0.pinned })
        }
        scheduleSave()
    }

    private func trimIfNeeded() {
        let nonPinned = items.filter { !$0.pinned }
        if nonPinned.count > limit {
            let toRemove = Array(nonPinned.dropFirst(limit))
            let idsToRemove = Set(toRemove.map { $0.id })
            deleteImageFiles(for: toRemove)
            items.removeAll { idsToRemove.contains($0.id) }
        }
    }

    private func deleteImageFiles(for items: [ClipItem]) {
        for item in items where item.isImage {
            if let fn = item.imageFileName { ImageStore.shared.delete(fileName: fn) }
        }
    }
}

// MARK: - Clipboard Watcher

final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private init() {}

    // Pasteboard markers used by password managers and similar tools.
    private static let transientTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    ]

    /// When we write to the pasteboard ourselves (auto-paste, copy actions), we stamp the
    /// resulting changeCount here so the watcher ignores it — preventing self-echo and
    /// preserving the original item's source-app attribution.
    private static var suppressedChangeCount: Int = -1
    static func suppressNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount
    }

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastStoredText: String?
    private var onNew: ((CapturedItem) -> Void)?

    deinit { timer?.invalidate() }

    func start(onNew: @escaping (CapturedItem) -> Void) {
        self.onNew = onNew
        stop()
        lastChangeCount = -1

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        DispatchQueue.main.async { [weak self] in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        guard change != lastChangeCount else { return }
        lastChangeCount = change

        // Ignore changes we caused ourselves (auto-paste / copy actions).
        if change == Self.suppressedChangeCount { return }

        // Skip items marked transient/concealed/auto-generated by other apps.
        let types = pb.types ?? []
        if types.contains(where: { Self.transientTypes.contains($0) }) { return }

        // Source app = whatever is frontmost at capture time (we're a background agent,
        // so the foreground app is the one the user copied from).
        let (srcBundle, srcName) = Self.currentSourceApp()

        // Prefer text; fall back to image (screenshots/copied images have no string).
        var text: String?
        if let s = pb.string(forType: .string) {
            text = s
        } else if let objects = pb.readObjects(forClasses: [NSString.self], options: nil) as? [NSString],
                  let first = objects.first {
            text = first as String
        }

        if let raw = text {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard trimmed != lastStoredText else { return }
            lastStoredText = trimmed
            onNew?(.text(raw, sourceBundleID: srcBundle, sourceAppName: srcName))
            return
        }

        if let (png, w, h) = Self.imageCapture(pb) {
            lastStoredText = nil
            onNew?(.image(png: png, width: w, height: h, sourceBundleID: srcBundle, sourceAppName: srcName))
        }
    }

    /// The frontmost non-self application, as (bundleID, localizedName).
    private static func currentSourceApp() -> (String?, String?) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return (nil, nil)
        }
        return (app.bundleIdentifier, app.localizedName)
    }

    /// Extracts PNG bytes + pixel dimensions from the pasteboard, normalizing TIFF → PNG.
    private static func imageCapture(_ pb: NSPasteboard) -> (Data, Int, Int)? {
        if let png = pb.data(forType: .png), let rep = NSBitmapImageRep(data: png) {
            return (png, rep.pixelsWide, rep.pixelsHigh)
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, rep.pixelsWide, rep.pixelsHigh)
        }
        return nil
    }
}

// MARK: - Hotkey Manager

final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    static var eventSpec = EventTypeSpec(
        eventClass: OSType(Int32(kEventClassKeyboard)),
        eventKind: UInt32(Int32(kEventHotKeyPressed))
    )

    static let signature: OSType = { OSType("Clip".fourCharCodeValue) }()

    static let eventHandlerCallback: EventHandlerUPP = { _, eventRef, _ in
        var receivedID = EventHotKeyID()
        let err = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        if err == noErr {
            if receivedID.signature == HotkeyManager.signature && receivedID.id == 1 {
                HotkeyManager.shared.handler?()
            }
        } else {
            Log.hotkey.error("GetEventParameter failed: \(err)")
        }
        return noErr
    }

    /// Registers (or re-registers) the global hotkey. Safe to call multiple times.
    func registerHotkey(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.handler = handler

            if let ref = self.hotKeyRef {
                let status = UnregisterEventHotKey(ref)
                if status != noErr { Log.hotkey.error("Unregister existing hotkey failed: \(status)") }
                self.hotKeyRef = nil
            }

            if self.eventHandlerRef == nil {
                var ref: EventHandlerRef?
                let installStatus = InstallEventHandler(
                    GetApplicationEventTarget(),
                    HotkeyManager.eventHandlerCallback,
                    1,
                    [HotkeyManager.eventSpec],
                    nil,
                    &ref
                )
                if installStatus != noErr {
                    Log.hotkey.error("InstallEventHandler failed: \(installStatus)")
                } else {
                    self.eventHandlerRef = ref
                }
            }

            let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: UInt32(1))
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &self.hotKeyRef
            )

            if status == noErr {
                Log.hotkey.info("Hotkey registered (keyCode=\(keyCode), mods=\(modifiers))")
            } else {
                Log.hotkey.error("RegisterEventHotKey failed: \(status)")
            }
        }
    }

    func unregisterHotkey() {
        if let ref = hotKeyRef {
            let status = UnregisterEventHotKey(ref)
            if status != noErr { Log.hotkey.error("Unregister hotkey failed: \(status)") }
            hotKeyRef = nil
        }
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
        handler = nil
    }
}

// MARK: - Auto Paster

/// Tracks the most-recently active non-self application and pastes into it
/// by synthesizing a Cmd-V keystroke after activating that app.
///
/// Requires Accessibility permission; prompts on first paste attempt. If the
/// user denies, the content still lands on the clipboard for a manual paste.
final class AutoPaster {
    static let shared = AutoPaster()
    private init() {}

    static var lastActiveApp: NSRunningApplication?
    private static var didPromptForAX = false

    static func startTracking() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                lastActiveApp = app
            }
        }
        // Seed with whatever's currently frontmost (the user, before us).
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = front
        }
    }

    /// Snapshots the current frontmost app as the paste target. Call this *before*
    /// activating our own app (e.g., before showing the floating panel).
    static func captureFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = app
            Log.autopaste.info("Captured target app: \(app.localizedName ?? "?", privacy: .public)")
        }
    }

    /// Copies `text` to the clipboard, then pastes into the previously active app.
    static func pasteIntoPreviousApp(text: String) {
        NSPasteboard.general.copyString(text)
        deliverPaste()
    }

    /// Copies image `png` to the clipboard, then pastes into the previously active app.
    static func pasteIntoPreviousApp(imageData png: Data) {
        NSPasteboard.general.copyImageData(png)
        deliverPaste()
    }

    private static func deliverPaste() {
        guard let app = lastActiveApp else {
            Log.autopaste.info("No previous app captured; content on clipboard only.")
            return
        }
        guard ensureAccessibilityTrust() else {
            Log.autopaste.info("Accessibility not trusted; content on clipboard only.")
            return
        }
        Log.autopaste.info("Activating target: \(app.localizedName ?? "?", privacy: .public) (pid=\(app.processIdentifier))")
        app.activate(options: [])

        // Wait for the target app to actually be frontmost before injecting the keystroke.
        // 500ms total budget, polled every 20ms.
        let deadline = Date().addingTimeInterval(0.5)
        waitUntilFrontmost(app: app, deadline: deadline)
    }

    private static func waitUntilFrontmost(app: NSRunningApplication, deadline: Date) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            sendCmdV()
            return
        }
        if Date() >= deadline {
            Log.autopaste.error("Target app did not become frontmost in time; clipboard only.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitUntilFrontmost(app: app, deadline: deadline)
        }
    }

    private static func ensureAccessibilityTrust() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !didPromptForAX {
            didPromptForAX = true
            let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return false
    }

    private static func sendCmdV() {
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: true)
        let up   = CGEvent(keyboardEventSource: nil, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        Log.autopaste.info("Posted Cmd-V")
    }
}

// MARK: - App Icon Provider

/// Resolves and caches app icons by bundle identifier, for the per-item source-app chip.
/// Main-thread only (NSWorkspace); cheap and cached, so safe to call during view body.
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID id: String?) -> NSImage? {
        guard let id, !id.isEmpty else { return nil }
        if let cached = cache[id] { return cached }
        var icon: NSImage?
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            icon = running.icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let icon { cache[id] = icon }
        return icon
    }
}

// MARK: - Utilities

extension String {
    /// Packs up to four ASCII code points into a 32-bit `FourCharCode`. Asserts that
    /// the input fits — silent truncation would produce a misleading signature.
    var fourCharCodeValue: FourCharCode {
        precondition(unicodeScalars.count <= 4, "fourCharCodeValue requires a string of at most 4 scalars; got \(unicodeScalars.count)")
        var result: FourCharCode = 0
        for scalar in unicodeScalars {
            result = (result << 8) + FourCharCode(scalar.value & 0xFF)
        }
        return result
    }
}

extension NSPasteboard {
    /// Writes a string and suppresses the resulting watcher echo.
    func copyString(_ string: String) {
        clearContents()
        setString(string, forType: .string)
        ClipboardWatcher.suppressNextChange()
    }

    /// Writes PNG image data and suppresses the resulting watcher echo.
    func copyImageData(_ png: Data) {
        clearContents()
        setData(png, forType: .png)
        ClipboardWatcher.suppressNextChange()
    }
}
