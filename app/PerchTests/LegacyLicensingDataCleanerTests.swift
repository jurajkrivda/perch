import Foundation
import Security
import XCTest

final class LegacyLicensingDataCleanerTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var directoryURL: URL!

    override func setUpWithError() throws {
        suiteName = "LegacyLicensingDataCleanerTests-\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directoryURL)
        userDefaults = nil
        directoryURL = nil
        suiteName = nil
    }

    func testSuccessfulMigrationRemovesOnlyLegacyDataAndWritesMarker() throws {
        let trialURL = directoryURL.appendingPathComponent("trial.json")
        let metadataURL = directoryURL.appendingPathComponent("license-state.json")
        let slotsURL = directoryURL.appendingPathComponent("slots.json")
        let lockURL = directoryURL.appendingPathComponent("Perch.lock")
        let arbitraryURL = directoryURL.appendingPathComponent("keep-me.txt")
        try Data("trial".utf8).write(to: trialURL)
        try Data("metadata".utf8).write(to: metadataURL)
        try Data("layouts".utf8).write(to: slotsURL)
        try Data("lock".utf8).write(to: lockURL)
        try Data("other".utf8).write(to: arbitraryURL)
        userDefaults.set(Date(), forKey: LegacyLicensingDataCleaner.trialDefaultsKey)

        var keychainDeleteCount = 0
        let cleaner = LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: directoryURL,
            deleteKeychainItem: {
                keychainDeleteCount += 1
                return errSecSuccess
            }
        )

        cleaner.runIfNeeded()

        XCTAssertEqual(keychainDeleteCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: slotsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: arbitraryURL.path))
        XCTAssertNil(userDefaults.object(forKey: LegacyLicensingDataCleaner.trialDefaultsKey))
        XCTAssertTrue(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))
    }

    func testCompletedMigrationDoesNotRunAgain() {
        userDefaults.set(true, forKey: LegacyLicensingDataCleaner.migrationMarkerKey)
        var keychainDeleteCount = 0
        let cleaner = LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: directoryURL,
            deleteKeychainItem: {
                keychainDeleteCount += 1
                return errSecSuccess
            }
        )

        cleaner.runIfNeeded()

        XCTAssertEqual(keychainDeleteCount, 0)
    }

    func testKeychainFailureStillCleansLocalDataButLeavesMarkerForRetry() throws {
        let trialURL = directoryURL.appendingPathComponent("trial.json")
        try Data("trial".utf8).write(to: trialURL)
        userDefaults.set(Date(), forKey: LegacyLicensingDataCleaner.trialDefaultsKey)

        let cleaner = LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: directoryURL,
            deleteKeychainItem: { errSecInteractionNotAllowed }
        )

        cleaner.runIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: trialURL.path))
        XCTAssertNil(userDefaults.object(forKey: LegacyLicensingDataCleaner.trialDefaultsKey))
        XCTAssertFalse(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))
    }

    func testMissingApplicationSupportLocationLeavesMarkerForRetry() {
        let cleaner = LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: nil,
            deleteKeychainItem: { errSecItemNotFound }
        )

        cleaner.runIfNeeded()

        XCTAssertFalse(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))
    }

    func testDirectoryAtLegacyPathIsPreservedAndMigrationRetries() throws {
        let directoryAtLegacyPath = directoryURL.appendingPathComponent("trial.json", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryAtLegacyPath,
            withIntermediateDirectories: false
        )
        try Data("keep".utf8).write(
            to: directoryAtLegacyPath.appendingPathComponent("nested.txt")
        )

        let cleaner = LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: directoryURL,
            deleteKeychainItem: { errSecItemNotFound }
        )
        cleaner.runIfNeeded()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directoryAtLegacyPath.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))

        try FileManager.default.removeItem(at: directoryAtLegacyPath)
        cleaner.runIfNeeded()
        XCTAssertTrue(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))
    }

    func testSymlinkAtLegacyPathIsUnlinkedWithoutTouchingTarget() throws {
        let targetURL = directoryURL.appendingPathComponent("keep-target.txt")
        let symlinkURL = directoryURL.appendingPathComponent("trial.json")
        try Data("keep".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )

        LegacyLicensingDataCleaner(
            userDefaults: userDefaults,
            applicationSupportDirectory: directoryURL,
            deleteKeychainItem: { errSecItemNotFound }
        ).runIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: symlinkURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("keep".utf8))
        XCTAssertTrue(userDefaults.bool(forKey: LegacyLicensingDataCleaner.migrationMarkerKey))
    }

    func testKeychainQueryTargetsOnlyTheLegacyGenericPassword() {
        let query = LegacyLicensingDataCleaner.legacyKeychainQuery

        XCTAssertEqual(query.count, 3)
        XCTAssertEqual(
            query[kSecClass as String] as? String,
            kSecClassGenericPassword as String
        )
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            LegacyLicensingDataCleaner.keychainService
        )
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            LegacyLicensingDataCleaner.keychainAccount
        )
    }
}
