import SwiftUI
import AppKit
import Foundation
import CryptoKit
import Security
import ServiceManagement
import Carbon
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

    private enum Keys {
        static let hotkeyCode    = "hotkey.keyCode"
        static let hotkeyMods    = "hotkey.modifiers"
        static let launchAtLogin = "launchAtLogin"
    }

    struct HotkeyConfig: Equatable {
        var keyCode: UInt32     // Carbon virtual key code
        var modifiers: UInt32   // Carbon modifier mask (cmdKey | optionKey | ...)
    }

    static let defaultHotkey = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
    )

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
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin(newValue)
        }
    }

    func syncLaunchAtLoginOnStartup() {
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
            Log.app.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
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

// MARK: - Persistence

final class PersistenceManager {
    static let shared = PersistenceManager()
    private init() {}

    private let fileName = "history.json.enc"
    private let currentSchemaVersion = 1

    struct HistoryFile: Codable {
        let version: Int
        let items: [ClipItem]
    }

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
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("ClipboardManager", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                    .posixPermissions: 0o700
                ])
            } catch {
                Log.persistence.error("Failed to create app support folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        return folder.appendingPathComponent(fileName)
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
                Log.persistence.error("Save failed: \(error.localizedDescription, privacy: .public)")
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
            Log.persistence.error("Failed to read history file: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let decrypted: Data
        do {
            decrypted = try KeyManager.shared.decrypt(data)
        } catch {
            Log.persistence.error("Decrypt failed; quarantining file. \(error.localizedDescription, privacy: .public)")
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
            Log.persistence.info("Quarantined corrupt history to \(target.lastPathComponent, privacy: .public)")
        } catch {
            Log.persistence.error("Quarantine failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - App Delegate & Entry

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var itemsVM: ItemsViewModel!
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Encryption key must exist before persistence load.
        do { try KeyManager.shared.ensureKeyExists() }
        catch { Log.crypto.error("ensureKeyExists failed: \(error.localizedDescription, privacy: .public)") }

        // 2. Load persisted history.
        itemsVM = ItemsViewModel()

        // 3. Sync launch-at-login with stored preference (idempotent; no-op when matched).
        Preferences.shared.syncLaunchAtLoginOnStartup()

        // 4. Track frontmost app for auto-paste target.
        AutoPaster.startTracking()

        // 5. Start clipboard watcher.
        ClipboardWatcher.shared.start { [weak self] text in
            self?.itemsVM?.addItem(text)
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
