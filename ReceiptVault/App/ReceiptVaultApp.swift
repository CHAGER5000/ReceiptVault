import SwiftUI
import SwiftData
import UIKit

// The app's entry point and its app-level plumbing: the vault (the one
// SwiftData container), where files live on disk, the settings keys with
// their defaults, and the app's error type.

@main
struct ReceiptVaultApp: App {
    @StateObject private var vault = VaultStore()
    @StateObject private var capture = CaptureModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LockGate {
                VaultContent()
            }
            .environmentObject(vault)
            .environmentObject(capture)
            // Outside the lock, so a shared file is moved into protected
            // staging at once and read after unlock.
            .onOpenURL { url in
                capture.enqueue(url)
            }
            .onAppear {
                vault.open()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                vault.open()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                vault.saveNow()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { vault.saveNow() }
            }
        }
    }
}

/// The open vault, or VaultUnavailableView while it cannot be opened. It
/// watches VaultStore itself, so it switches as soon as the container opens.
private struct VaultContent: View {
    @EnvironmentObject private var vault: VaultStore

    var body: some View {
        if let container = vault.container {
            RootView()
                .modelContainer(container)
        } else {
            VaultUnavailableView()
        }
    }
}

// MARK: - Vault

/// Owns the app's single ModelContainer. With "complete" protection the store
/// cannot be read while the phone is locked, so the container is opened only
/// when protected data is available (never with fatalError). An iOS pre-warm
/// while locked shows VaultUnavailableView and retries on unlock.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var container: ModelContainer? = nil
    @Published private(set) var errorText: String? = nil
    @Published private(set) var waitingForUnlock: Bool = false

    /// Opens the vault. Does nothing when it is already open; waits for the
    /// unlock when protected data is not available yet.
    func open() {
        guard container == nil else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            waitingForUnlock = true
            return
        }
        waitingForUnlock = false
        Storage.performPendingWipe()
        Storage.prepareDirectories()
        // At launch no share sheet can be open, so every old export goes.
        FileVault.clearExports()
        do {
            container = try Storage.makeContainer()
            errorText = nil
            Storage.stampProtection()
        } catch {
            errorText = VaultStore.failureText(error)
        }
    }

    /// Saves pending changes (on inactive, on background, and before the
    /// phone locks the store away).
    func saveNow() {
        guard let context = container?.mainContext, context.hasChanges else { return }
        try? context.save()
    }

    private static func failureText(_ error: Error) -> String {
        var detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while detail.hasSuffix(".") { detail.removeLast() }
        let reason = detail.isEmpty ? "" : " (\(detail))"
        return "The database could not be opened\(reason). Tap Retry, or close ReceiptVault and open it again. If it keeps happening, restart your iPhone."
    }
}

// MARK: - Storage

/// Everything lives in Application Support/ReceiptVault with iOS "complete"
/// file protection, so it is encrypted whenever the phone is locked.
/// Exports go to tmp/Export.
enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReceiptVault", isDirectory: true)
    }

    /// Originals and thumbnails.
    static var filesDirectory: URL {
        directory.appendingPathComponent("Files", isDirectory: true)
    }

    /// Shared files waiting to be read.
    static var incomingDirectory: URL {
        stagingDirectory.appendingPathComponent("Incoming", isDirectory: true)
    }

    /// Where a backup is decrypted before its files are adopted.
    static var restoreDirectory: URL {
        stagingDirectory.appendingPathComponent("Restore", isDirectory: true)
    }

    /// Evidence PDFs, CSV files and backups on their way to the share sheet.
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
    }

    static var storeURL: URL {
        directory.appendingPathComponent("vault.store", isDirectory: false)
    }

    /// Always left out of device backups.
    private static var stagingDirectory: URL {
        directory.appendingPathComponent("Staging", isDirectory: true)
    }

    /// The database and its SQLite side files.
    private static var storeFiles: [URL] {
        [storeURL,
         directory.appendingPathComponent("vault.store-wal", isDirectory: false),
         directory.appendingPathComponent("vault.store-shm", isDirectory: false)]
    }

    private static var completeProtection: [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.complete]
    }

    /// Creates every folder with complete protection and stamps it again
    /// (at every launch), keeps Staging out of backups, and applies the
    /// 'Leave out of backup' setting to the vault.
    static func prepareDirectories() {
        let manager = FileManager.default
        let folders: [URL] = [directory, filesDirectory, stagingDirectory,
                              incomingDirectory, restoreDirectory, exportDirectory]
        for folder in folders {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                         attributes: completeProtection)
            try? manager.setAttributes(completeProtection, ofItemAtPath: folder.path)
        }
        var staging = stagingDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? staging.setResourceValues(values)
        applyBackupSetting(AppSettings.excludeFromBackup)
    }

    /// The three models in one store at storeURL, never synced.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([VaultItem.self, StoredFile.self, Deadline.self])
        let config = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Complete protection on the store files SwiftData has created.
    static func stampProtection() {
        let manager = FileManager.default
        for file in storeFiles where manager.fileExists(atPath: file.path) {
            try? manager.setAttributes(completeProtection, ofItemAtPath: file.path)
        }
    }

    /// Includes the whole vault in device backups, or leaves it out.
    static func applyBackupSetting(_ exclude: Bool) {
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = exclude
        try? dir.setResourceValues(values)
    }

    /// After 'Delete all data': removes the store files before the container
    /// opens, because SQLite free pages can keep deleted text, together with
    /// Files/ and Staging/Restore. Runs once: the flag is cleared either way.
    ///
    /// Deleting cleared Files/ and the staging folders, so anything found
    /// there now was added afterwards. A file in Files/ means something was
    /// captured or restored since (it is in the store), and nothing is
    /// removed; Staging/Incoming is kept, as it can only hold files shared since.
    static func performPendingWipe() {
        guard AppSettings.pendingWipe else { return }
        AppSettings.pendingWipe = false
        if holdsFiles(filesDirectory) { return }
        let manager = FileManager.default
        let doomed: [URL] = storeFiles + [filesDirectory, restoreDirectory]
        for url in doomed where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }

    private static func holdsFiles(_ dir: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.contains { name in !name.hasPrefix(".") }
    }
}

// MARK: - Settings

/// UserDefaults keys. None of the settings are sensitive.
enum SettingsKeys {
    static let lockEnabled = "lockEnabled"
    static let excludeFromBackup = "excludeFromBackup"
    static let defaultJurisdiction = "defaultJurisdiction"
    static let defaultCurrency = "defaultCurrency"
    static let defaultChannel = "defaultChannel"
    static let reminderHour = "reminderHour"
    static let reminderMinute = "reminderMinute"
    static let privateReminderText = "privateReminderText"
    static let rulesJSON = "rulesJSON"
    static let lastBackupAt = "lastBackupAt"
    static let backupReminderDays = "backupReminderDays"
    static let pendingWipe = "pendingWipe"
    static let onboardingDone = "onboardingDone"
}

/// The settings for code outside views, with the same defaults as every
/// @AppStorage that uses these keys. A Bool that was never set is read as
/// missing (object(forKey:)), not as false.
enum AppSettings {
    private static var defaults: UserDefaults { UserDefaults.standard }

    static var lockEnabled: Bool {
        AppSettings.flag(SettingsKeys.lockEnabled, fallback: true)
    }

    static var excludeFromBackup: Bool {
        AppSettings.flag(SettingsKeys.excludeFromBackup, fallback: false)
    }

    static var defaultJurisdiction: Jurisdiction {
        let raw = defaults.string(forKey: SettingsKeys.defaultJurisdiction) ?? ""
        return Jurisdiction(rawValue: raw) ?? Jurisdiction.englandWales
    }

    static var defaultCurrency: String {
        let raw = defaults.string(forKey: SettingsKeys.defaultCurrency) ?? ""
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.isEmpty ? "GBP" : code
    }

    static var defaultChannel: PurchaseChannel {
        let raw = defaults.string(forKey: SettingsKeys.defaultChannel) ?? ""
        return PurchaseChannel(rawValue: raw) ?? PurchaseChannel.store
    }

    /// 0...23.
    static var reminderHour: Int {
        min(max(AppSettings.number(SettingsKeys.reminderHour, fallback: 9), 0), 23)
    }

    /// 0...59.
    static var reminderMinute: Int {
        min(max(AppSettings.number(SettingsKeys.reminderMinute, fallback: 0), 0), 59)
    }

    static var privateReminderText: Bool {
        AppSettings.flag(SettingsKeys.privateReminderText, fallback: true)
    }

    /// Stored as seconds since 1970; 0 means never.
    static var lastBackupAt: Date? {
        get {
            let stamp = defaults.double(forKey: SettingsKeys.lastBackupAt)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set {
            let stamp: Double = newValue?.timeIntervalSince1970 ?? 0
            defaults.set(stamp, forKey: SettingsKeys.lastBackupAt)
        }
    }

    /// At least 1.
    static var backupReminderDays: Int {
        max(1, AppSettings.number(SettingsKeys.backupReminderDays, fallback: 30))
    }

    static var pendingWipe: Bool {
        get { AppSettings.flag(SettingsKeys.pendingWipe, fallback: false) }
        set { defaults.set(newValue, forKey: SettingsKeys.pendingWipe) }
    }

    static var onboardingDone: Bool {
        get { AppSettings.flag(SettingsKeys.onboardingDone, fallback: false) }
        set { defaults.set(newValue, forKey: SettingsKeys.onboardingDone) }
    }

    private static func flag(_ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }

    private static func number(_ key: String, fallback: Int) -> Int {
        (defaults.object(forKey: key) as? Int) ?? fallback
    }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case unreadable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file could not be read."
        case .message(let m): return m
        }
    }
}
