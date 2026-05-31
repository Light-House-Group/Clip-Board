import SwiftUI
import AppKit
import Foundation
import CryptoKit
import Security
import ServiceManagement
import Carbon
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - Logging

enum Log {
    static let app          = Logger(subsystem: "com.clipboard.manager", category: "app")
    static let crypto       = Logger(subsystem: "com.clipboard.manager", category: "crypto")
    static let persistence  = Logger(subsystem: "com.clipboard.manager", category: "persistence")
    static let hotkey       = Logger(subsystem: "com.clipboard.manager", category: "hotkey")
    static let clipboard    = Logger(subsystem: "com.clipboard.manager", category: "clipboard")
    static let menubar      = Logger(subsystem: "com.clipboard.manager", category: "menubar")
    static let autopaste    = Logger(subsystem: "com.clipboard.manager", category: "autopaste")
}

// MARK: - Preferences

final class Preferences {
    static let shared = Preferences()
    private init() {}
    private let defaults = UserDefaults.standard

    /// Posted when `historySize` changes. ItemsViewModel listens for this and re-trims.
    static let historySizeChanged = Notification.Name("com.clipboard.manager.historySizeChanged")

    private enum Keys {
        static let hotkeyCode    = "hotkey.keyCode"
        static let hotkeyMods    = "hotkey.modifiers"
        static let launchAtLogin = "launchAtLogin"
        static let historySize   = "historySize"
    }

    struct HotkeyConfig: Equatable {
        var keyCode: UInt32     // Carbon virtual key code
        var modifiers: UInt32   // Carbon modifier mask (cmdKey | optionKey | ...)
    }

    static let defaultHotkey = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(optionKey)
    )

    /// Allowed history-size presets shown in the menu. Anything outside this set still
    /// works (the getter accepts any positive int from defaults), but the UI surfaces
    /// these so users don't pick pathological values. No "Unlimited" — truly unbounded
    /// history breaks search latency, scroll perf, and per-save encryption time.
    static let historySizePresets = [50, 100, 250, 500, 1000]
    static let defaultHistorySize = 100

    var hotkey: HotkeyConfig {
        get {
            let k = (defaults.object(forKey: Keys.hotkeyCode) as? Int).map(UInt32.init) ?? Self.defaultHotkey.keyCode
            let m = (defaults.object(forKey: Keys.hotkeyMods) as? Int).map(UInt32.init) ?? Self.defaultHotkey.modifiers
            return HotkeyConfig(keyCode: k, modifiers: m)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.hotkeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Keys.hotkeyMods)
        }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin(newValue)
        }
    }

    /// Max number of unpinned items kept in history. Pinned items are always preserved.
    /// Clamped to [10, 5000] on read to guarantee a sane bound even if the stored value
    /// has been hand-edited.
    var historySize: Int {
        get {
            let raw = defaults.object(forKey: Keys.historySize) as? Int ?? Self.defaultHistorySize
            return max(10, min(5000, raw))
        }
        set {
            let clamped = max(10, min(5000, newValue))
            defaults.set(clamped, forKey: Keys.historySize)
            NotificationCenter.default.post(name: Self.historySizeChanged, object: nil)
        }
    }

    /// Reconcile the SMAppService registration with the stored preference, but only when
    /// the user has *explicitly* set a value. A fresh install must not silently register
    /// itself with LaunchServices — that's exactly the kind of invisible-install behavior
    /// the rest of this app is built to avoid.
    func syncLaunchAtLoginOnStartup() {
        guard defaults.object(forKey: Keys.launchAtLogin) != nil else { return }
        applyLaunchAtLogin(launchAtLogin)
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        let alreadyOn = (SMAppService.mainApp.status == .enabled)
        guard alreadyOn != on else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - KeyManager

enum KeyManagerError: Error {
    case keyGenerationFailed
    case keychainError(status: OSStatus)
    case keyNotFound
    case encryptionFailed
    case decryptionFailed
    case invalidUTF8
}

final class KeyManager {
    static let shared = KeyManager()
    private init() {}

    private let service = "com.clipboard.manager"
    private let account = "com.clipboard.manager.symmetrickey"
    private var cachedKey: SymmetricKey?

    func ensureKeyExists() throws {
        if (try? loadKey()) != nil { return }
        let key = SymmetricKey(size: .bits256)
        try storeKeyInKeychain(key: key)
        cachedKey = key
    }

    func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyManagerError.keychainError(status: status)
        }
        cachedKey = nil
    }

    func encrypt(data: Data) throws -> Data {
        let key = try getOrLoadKey()
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else { throw KeyManagerError.encryptionFailed }
            return combined
        } catch {
            throw KeyManagerError.encryptionFailed
        }
    }

    func decrypt(_ encryptedData: Data) throws -> Data {
        let key = try getOrLoadKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw KeyManagerError.decryptionFailed
        }
    }

    private func loadKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyManagerError.keyNotFound
        }
        let key = SymmetricKey(data: data)
        cachedKey = key
        return key
    }

    private func storeKeyInKeychain(key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        SecItemDelete(addQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyManagerError.keychainError(status: status)
        }
        cachedKey = key
    }

    private func getOrLoadKey() throws -> SymmetricKey {
        if let key = cachedKey { return key }
        return try loadKey()
    }
}

// MARK: - App Support Paths

/// Centralized on-disk locations, each created with tight permissions once at first use.
///
/// Resolves to `~/Library/Application Support/ClipboardManager`. The directory is created
/// 0700 on first access so other users on the machine can't read it. (Releases 1.0.0–1.2.2
/// ran sandboxed and stored under `~/Library/Containers/<bundle-id>/Data/...`; 1.2.3+ is
/// unsandboxed and migrates the old container payload via `migrateLegacyContainerIfNeeded()`.)
enum AppPaths {
    /// `…/Application Support/ClipboardManager` (0700). Cached — created once.
    static let base: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let folder = appSupport.appendingPathComponent("ClipboardManager", isDirectory: true)
        ensureDirectory(folder)
        return folder
    }()

    /// `…/ClipboardManager/images` (0700) — encrypted per-image files. Cached.
    static let imagesFolder: URL = {
        let folder = base.appendingPathComponent("images", isDirectory: true)
        ensureDirectory(folder)
        return folder
    }()

    /// One-time migration of pre-1.2.3 sandbox-container history into the unsandboxed
    /// Application Support location. Idempotent and safe: only runs when the destination
    /// has no encrypted history yet and a legacy container payload exists. Never overwrites
    /// newer data; never deletes the source (so a downgrade still finds the old store).
    /// Call once at launch, BEFORE the persistence manager loads.
    static func migrateLegacyContainerIfNeeded() {
        let fm = FileManager.default
        let historyName = "history.json.enc"
        let destHistory = base.appendingPathComponent(historyName)
        if fm.fileExists(atPath: destHistory.path) { return }

        // Reconstruct the old sandbox container path manually — it's a regular path in
        // the user's home directory; we just hard-code the bundle ID component.
        // NOTE: appendingPathComponent percent-encodes embedded slashes, so chain one
        // component per call (passing "Library/Containers" as one arg is wrong).
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        guard let home = ProcessInfo.processInfo.environment["HOME"].map(URL.init(fileURLWithPath:)) else { return }
        let legacy = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ClipboardManager", isDirectory: true)
        let legacyHistory = legacy.appendingPathComponent(historyName)
        guard fm.fileExists(atPath: legacyHistory.path) else { return }

        Log.app.notice("Migrating legacy sandbox-container history into Application Support.")
        do {
            try fm.copyItem(at: legacyHistory, to: destHistory)
        } catch {
            Log.app.error("Legacy history copy failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        // Carry images over too if present.
        let legacyImages = legacy.appendingPathComponent("images", isDirectory: true)
        if let names = try? fm.contentsOfDirectory(atPath: legacyImages.path) {
            for name in names {
                let src = legacyImages.appendingPathComponent(name)
                let dst = imagesFolder.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { continue }
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    private static func ensureDirectory(_ url: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            Log.persistence.error("Failed to create \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - Image Store

/// Stores clipboard images as individual AES-GCM-encrypted files, one per item, under
/// `ClipboardManager/images`. Per-file (rather than embedding bytes in the single history
/// JSON) keeps text-copy saves cheap and avoids rewriting every image on each change.
///
/// Thumbnails are produced via ImageIO (no full decode) and cached in memory for smooth
/// scrolling; full images are decoded on demand for the hover preview and for pasting.
final class ImageStore {
    static let shared = ImageStore()
    private init() {}

    private let ioQueue = DispatchQueue(label: "ImageStore.IO", qos: .utility)
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()

    /// PNG bytes for images whose encrypted disk write hasn't landed yet, so a freshly
    /// captured image renders immediately if the panel is already open. Lock-guarded
    /// because reads happen off-main (thumbnail decode) while writes happen on main.
    private let pendingLock = NSLock()
    private var pendingPNG: [String: Data] = [:]

    private func url(for fileName: String) -> URL {
        AppPaths.imagesFolder.appendingPathComponent(fileName)
    }

    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Encrypts and writes PNG bytes asynchronously (file mode 0600). Seeds the in-memory
    /// `pendingPNG` synchronously so the new item is already renderable (decode via
    /// `loadPNG`) before the write lands; the ImageIO thumbnail downscale runs on `ioQueue`
    /// (large screenshots are too heavy to decode on main).
    func save(png: Data, fileName: String) {
        pendingLock.lock(); pendingPNG[fileName] = png; pendingLock.unlock()

        let url = url(for: fileName)
        let thumbKey = cacheKey(fileName, 800)
        ioQueue.async {
            // NSCache is thread-safe; populate the thumbnail off-main.
            if let thumb = Self.makeThumbnail(from: png, maxPixelSize: 800) {
                self.thumbnailCache.setObject(thumb, forKey: thumbKey)
            }
            do {
                let encrypted = try KeyManager.shared.encrypt(data: png)
                try encrypted.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.persistence.error("Image save failed: \(error.localizedDescription, privacy: .private)")
            }
            self.pendingLock.lock(); self.pendingPNG[fileName] = nil; self.pendingLock.unlock()
        }
    }

    func delete(fileName: String) {
        pendingLock.lock(); pendingPNG[fileName] = nil; pendingLock.unlock()
        thumbnailCache.removeObject(forKey: cacheKey(fileName, 800))
        let url = url(for: fileName)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Decrypts and returns the raw PNG bytes (used for pasting and full-image decode).
    func loadPNG(fileName: String) -> Data? {
        pendingLock.lock(); let pending = pendingPNG[fileName]; pendingLock.unlock()
        if let pending { return pending }
        let url = url(for: fileName)
        guard let blob = try? Data(contentsOf: url) else { return nil }
        return try? KeyManager.shared.decrypt(blob)
    }

    /// Full-resolution image for the hover preview.
    func loadFullImage(fileName: String) -> NSImage? {
        guard let png = loadPNG(fileName: fileName) else { return nil }
        return NSImage(data: png)
    }

    /// Downscaled thumbnail (cached) for list rows. `maxPixelSize` is the longest edge.
    func loadThumbnail(fileName: String, maxPixelSize: Int) -> NSImage? {
        let key = cacheKey(fileName, maxPixelSize)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let png = loadPNG(fileName: fileName),
              let image = Self.makeThumbnail(from: png, maxPixelSize: maxPixelSize) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    /// Efficient downscale via ImageIO (no full bitmap decode).
    private static func makeThumbnail(from png: Data, maxPixelSize: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Removes encrypted image files no longer referenced by any history item.
    func pruneOrphans(referenced: Set<String>) {
        ioQueue.async {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: AppPaths.imagesFolder.path) else { return }
            for name in names where !referenced.contains(name) {
                try? fm.removeItem(at: self.url(for: name))
            }
        }
    }

    private func cacheKey(_ fileName: String, _ size: Int) -> NSString {
        "\(fileName)@\(size)" as NSString
    }
}

// MARK: - Persistence

/// `nonisolated` so its Codable conformance is callable from the persistence IO queue
/// despite the project's `-default-isolation=MainActor` flag.
private nonisolated struct HistoryFile: Codable {
    let version: Int
    let items: [ClipItem]
}

final class PersistenceManager {
    static let shared = PersistenceManager()
    private init() {}

    private let fileName = "history.json.enc"
    private let currentSchemaVersion = 2

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let ioQueue = DispatchQueue(label: "PersistenceManager.IO", qos: .utility)

    private var fileURL: URL {
        AppPaths.base.appendingPathComponent(fileName)
    }

    /// Caller must invoke on the main thread (items is snapshotted before async I/O).
    func save(items: [ClipItem]) {
        let url = fileURL
        let snapshot = items
        let version = currentSchemaVersion
        ioQueue.async {
            do {
                let file = HistoryFile(version: version, items: snapshot)
                let jsonData = try PersistenceManager.encoder.encode(file)
                let encrypted = try KeyManager.shared.encrypt(data: jsonData)
                try encrypted.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                Log.persistence.error("Save failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func load() -> [ClipItem] {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.persistence.error("Failed to read history file: \(error.localizedDescription, privacy: .private)")
            return []
        }
        let decrypted: Data
        do {
            decrypted = try KeyManager.shared.decrypt(data)
        } catch {
            Log.persistence.error("Decrypt failed; quarantining file. \(error.localizedDescription, privacy: .private)")
            quarantine(url: url)
            return []
        }
        if let file = try? Self.decoder.decode(HistoryFile.self, from: decrypted) {
            return file.items
        }
        if let legacy = try? Self.decoder.decode([ClipItem].self, from: decrypted) {
            Log.persistence.info("Migrated legacy history (unversioned).")
            return legacy
        }
        Log.persistence.error("History payload not decodable; quarantining.")
        quarantine(url: url)
        return []
    }

    private func quarantine(url: URL) {
        let ts = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent().appendingPathComponent("history.broken-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            Log.persistence.info("Quarantined corrupt history to \(target.lastPathComponent, privacy: .private)")
        } catch {
            Log.persistence.error("Quarantine failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - App Delegate & Entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var itemsVM: ItemsViewModel!
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. One-time migration of pre-1.2.3 sandbox-container history into the
        //    unsandboxed Application Support directory. No-op after first run.
        //    Runs BEFORE KeyManager: a re-signed binary can trigger a modal Keychain
        //    re-authorization prompt that blocks ensureKeyExists for the first few
        //    seconds, and we don't want migration gated on the user dismissing it.
        AppPaths.migrateLegacyContainerIfNeeded()

        // 1. Encryption key must exist before persistence load.
        do { try KeyManager.shared.ensureKeyExists() }
        catch { Log.crypto.error("ensureKeyExists failed: \(error.localizedDescription, privacy: .private)") }

        // 2. Load persisted history.
        itemsVM = ItemsViewModel()

        // 3. Sync launch-at-login with stored preference (idempotent; no-op when matched).
        Preferences.shared.syncLaunchAtLoginOnStartup()

        // 4. Track frontmost app for auto-paste target.
        AutoPaster.startTracking()

        // 5. Start clipboard watcher (text + images, with source-app attribution).
        ClipboardWatcher.shared.start { [weak self] captured in
            guard let vm = self?.itemsVM else { return }
            switch captured {
            case let .text(text, reps, bundleID, appName):
                vm.addText(text, richRepresentations: reps,
                           sourceBundleID: bundleID, sourceAppName: appName)
            case let .image(png, width, height, bundleID, appName):
                vm.addImage(png: png, width: width, height: height,
                            sourceBundleID: bundleID, sourceAppName: appName)
            }
        }

        // 6. Register hotkey from preferences (no UI interaction needed).
        registerHotkeyFromPreferences()

        // 7. Install status item + right-click menu.
        menuBarController = MenuBarController(
            itemsVM: itemsVM,
            onShortcutChanged: { [weak self] in self?.registerHotkeyFromPreferences() }
        )

        // 8. Pre-warm the floating panel so the first user-visible show is instant
        //    (NSPanel + NSHostingView + SwiftUI first-render is the expensive part).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let vm = self?.itemsVM else { return }
            HistoryWindowController.shared.prewarm(itemsVM: vm)
        }

        Log.app.info("Launched. Services online.")
    }

    func registerHotkeyFromPreferences() {
        let cfg = Preferences.shared.hotkey
        HotkeyManager.shared.registerHotkey(keyCode: cfg.keyCode, modifiers: cfg.modifiers) { [weak self] in
            guard let self, let vm = self.itemsVM else { return }
            // Capture the user's foreground app BEFORE we steal focus by showing the panel.
            AutoPaster.captureFrontmost()
            let loc = NSEvent.mouseLocation
            HistoryWindowController.shared.toggle(at: loc, itemsVM: vm)
        }
    }
}

@main
struct Clip_BoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() } // No visible scene; UI lives in the status item / floating panel.
    }
}
