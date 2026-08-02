import Foundation
import Security
import Darwin

/// Removes data written by the discontinued trial and licensing subsystem.
///
/// The migration is deliberately narrow: saved layouts share the same
/// Application Support directory and must never be touched.
struct LegacyLicensingDataCleaner {
    static let migrationMarkerKey = "PerchDidRemoveLegacyLicensingDataV1"
    static let trialDefaultsKey = "PerchTrialFirstLaunch"

    static let keychainService = "com.jurajkrivda.perch"
    static let keychainAccount = "license"
    private static let legacyFileNames = ["trial.json", "license-state.json"]

    private let userDefaults: UserDefaults
    private let applicationSupportDirectory: URL?
    private let deleteKeychainItem: () -> OSStatus

    init(
        userDefaults: UserDefaults = .standard,
        applicationSupportDirectory: URL? = Self.defaultApplicationSupportDirectory(),
        deleteKeychainItem: @escaping () -> OSStatus = Self.deleteLegacyKeychainItem
    ) {
        self.userDefaults = userDefaults
        self.applicationSupportDirectory = applicationSupportDirectory
        self.deleteKeychainItem = deleteKeychainItem
    }

    func runIfNeeded() {
        guard !userDefaults.bool(forKey: Self.migrationMarkerKey) else {
            return
        }

        var cleanupSucceeded = true

        let keychainStatus = deleteKeychainItem()
        if keychainStatus != errSecSuccess && keychainStatus != errSecItemNotFound {
            AppLog.persistence.error("Failed to remove legacy Keychain data (status \(keychainStatus, privacy: .public)); cleanup will retry")
            cleanupSucceeded = false
        }

        if let applicationSupportDirectory {
            for fileName in Self.legacyFileNames {
                let fileURL = applicationSupportDirectory.appendingPathComponent(fileName)
                if unlink(fileURL.path) != 0 {
                    let errorCode = errno
                    if errorCode != ENOENT {
                        AppLog.persistence.error("Failed to unlink legacy local data (errno \(errorCode, privacy: .public)); cleanup will retry")
                        cleanupSucceeded = false
                    }
                }
            }
        } else {
            AppLog.persistence.error("Unable to locate Application Support for legacy cleanup; cleanup will retry")
            cleanupSucceeded = false
        }

        userDefaults.removeObject(forKey: Self.trialDefaultsKey)
        guard cleanupSucceeded else {
            return
        }
        userDefaults.set(true, forKey: Self.migrationMarkerKey)
    }

    static func defaultApplicationSupportDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Perch", isDirectory: true)
    }

    static var legacyKeychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func deleteLegacyKeychainItem() -> OSStatus {
        SecItemDelete(legacyKeychainQuery as CFDictionary)
    }
}
