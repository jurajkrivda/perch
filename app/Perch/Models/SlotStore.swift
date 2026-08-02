import Foundation
import Darwin

actor SlotStore {
    enum StoreError: LocalizedError, Equatable {
        case applicationSupportDirectoryUnavailable
        case layoutNotFound(String)
        case unsupportedSchemaVersion(found: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .applicationSupportDirectoryUnavailable:
                "The Application Support directory is unavailable."
            case let .layoutNotFound(layoutID):
                "Layout not found: \(layoutID)."
            case let .unsupportedSchemaVersion(found, supported):
                "This layout file uses schema version \(found), but this version of Perch supports up to version \(supported)."
            }
        }
    }

    static let fileName = "slots.json"

    private static let directoryPermissions: NSNumber = 0o700
    private static let storeFilePermissions: NSNumber = 0o600

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private struct StoreHeader: Decodable {
        var version: Int?
    }

    private struct Version1Document: Decodable {
        var slots: [Slot]
        var settings: PerchSettings
    }

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.fileURL = try fileURL ?? Self.defaultStoreURL(fileManager: fileManager)
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    var storeURL: URL {
        fileURL
    }

    func load() throws -> SlotStoreDocument {
        try hardenExistingStorePermissions()

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SlotStoreDocument()
        }

        let data = try Data(contentsOf: fileURL)
        let result: (document: SlotStoreDocument, wasMigrated: Bool)
        do {
            result = try decodeAndMigrate(data)
            try result.document.validate()
        } catch let error as StoreError {
            // A newer Perch may have written this file. Preserve it byte-for-byte
            // so installing an older build cannot destroy otherwise valid data.
            throw error
        } catch {
            try quarantineCorruptStore(decodeError: error)
            return SlotStoreDocument()
        }

        // Keep migration persistence outside the corrupt-data recovery block:
        // a disk or permission failure must not quarantine a valid legacy file.
        if result.wasMigrated {
            try save(result.document)
            AppLog.persistence.info(
                "Migrated layout store to schema version \(SlotStoreDocument.currentVersion)"
            )
        }

        return result.document
    }

    private func quarantineCorruptStore(decodeError: Error) throws {
        let quarantineURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)")

        do {
            try fileManager.moveItem(at: fileURL, to: quarantineURL)
        } catch {
            AppLog.persistence.error(
                "Store file is corrupt and could not be quarantined: \(error.localizedDescription, privacy: .public)"
            )
            throw decodeError
        }

        AppLog.persistence.error(
            "Store file was corrupt; moved to \(quarantineURL.lastPathComponent, privacy: .public) and reset to defaults: \(decodeError.localizedDescription, privacy: .public)"
        )
    }

    func save(_ document: SlotStoreDocument) throws {
        try document.validate()

        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try fileManager.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: directoryURL.path
        )

        let data = try encoder.encode(document)
        let temporaryURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: Self.storeFilePermissions],
            ofItemAtPath: temporaryURL.path
        )

        if rename(temporaryURL.path, fileURL.path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try fileManager.setAttributes(
            [.posixPermissions: Self.storeFilePermissions],
            ofItemAtPath: fileURL.path
        )
    }

    @discardableResult
    func update(_ mutate: @Sendable (inout SlotStoreDocument) throws -> Void) throws -> SlotStoreDocument {
        var document = try load()
        try mutate(&document)
        document.reconcileDisabledDefaultSaveHotkeys()
        try save(document)
        return document
    }

    func createLayout(name: String) throws -> Slot {
        var document = try load()
        document.materializeEffectiveRestoreHotkeys()
        let defaultRestoreHotkey = HotkeyBinding.defaultRestore(for: document.slots.count)
        let slot = Slot(
            id: UUID().uuidString.lowercased(),
            name: name,
            restoreHotkey: defaultRestoreHotkey,
            restoreHotkeyDisabled: defaultRestoreHotkey == nil
        )

        document.slots.append(slot)
        if let conflict = document.hotkeyConflict(for: slot.restoreHotkey, layoutID: slot.id) {
            throw SlotStoreDocument.ValidationError.hotkeyConflict(conflict)
        }
        try save(document)

        return slot
    }

    func renameLayout(id: String, name: String) throws {
        var document = try load()
        let slotIndex = try index(of: id, in: document)

        document.slots[slotIndex].name = name
        try save(document)
    }

    func deleteLayout(id: String) throws {
        var document = try load()
        let slotIndex = try index(of: id, in: document)

        document.materializeEffectiveRestoreHotkeys()
        document.slots.remove(at: slotIndex)
        document.reconcileDisabledDefaultSaveHotkeys()
        try save(document)
    }

    func resetToDefaults() throws -> SlotStoreDocument {
        let document = SlotStoreDocument()
        try save(document)
        return document
    }

    private func index(of layoutID: String, in document: SlotStoreDocument) throws -> Int {
        guard let index = document.slots.firstIndex(where: { $0.id == layoutID }) else {
            throw StoreError.layoutNotFound(layoutID)
        }

        return index
    }

    private static func defaultStoreURL(fileManager: FileManager) throws -> URL {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.applicationSupportDirectoryUnavailable
        }

        return applicationSupportURL
            .appendingPathComponent("Perch", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func decodeAndMigrate(_ data: Data) throws -> (document: SlotStoreDocument, wasMigrated: Bool) {
        let header = try decoder.decode(StoreHeader.self, from: data)
        let version = header.version ?? 1

        guard version <= SlotStoreDocument.currentVersion else {
            throw StoreError.unsupportedSchemaVersion(
                found: version,
                supported: SlotStoreDocument.currentVersion
            )
        }

        switch version {
        case 1:
            let legacy = try decoder.decode(Version1Document.self, from: data)
            var migrated = SlotStoreDocument(
                slots: legacy.slots,
                settings: legacy.settings
            )
            migrated.migrateLegacyHotkeyDefaults()
            return (migrated, true)
        case 2:
            var migrated = try decoder.decode(SlotStoreDocument.self, from: data)
            // Schema v3 only adds Slot.capturedTopology as an optional field.
            // Existing layouts intentionally keep it nil until next saved.
            migrated.version = SlotStoreDocument.currentVersion
            return (migrated, true)
        case SlotStoreDocument.currentVersion:
            return (try decoder.decode(SlotStoreDocument.self, from: data), false)
        default:
            throw SlotStoreDocument.ValidationError.invalidVersion(version)
        }
    }

    private func hardenExistingStorePermissions() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.setAttributes(
                [.posixPermissions: Self.directoryPermissions],
                ofItemAtPath: directoryURL.path
            )
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.setAttributes(
                [.posixPermissions: Self.storeFilePermissions],
                ofItemAtPath: fileURL.path
            )
        }
    }
}
